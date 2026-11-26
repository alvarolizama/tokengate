defmodule Tokengate.SmartRouter.Classifier do
  @moduledoc """
  Layer 2: the on-demand classifier. One `Decisions.post/4` call answers the
  two questions the deterministic layers could not: **which use case** this
  request is, and (when the client gave no reasoning effort) **how much effort**
  it needs.

  ## Strictly on demand

  `classify/4` is only reached by the engine when two or more viable use cases
  remain, `router_configs.decision_model_id` is set, the fast path did not
  fire, no rule forced a use case and a session pin missed. With a `nil`
  decision model the engine never gets here: purely deterministic mode makes
  zero classifier calls.

  ## One request, plain text

  Two wires, one question. With `model_type: "decision"` the call is a single
  choice-question pair (`use_case`, plus `effort` when unknown) posted through
  `Decisions.post/4`. With `model_type: "llm"` the same question goes out as a
  compact chat completion (`temperature: 0`, `max_tokens: 150`) that must answer
  pure JSON — `{"use_case", "effort", "confidence"}` — and both land in the same
  `result` (with the real `usage` and `latency_ms`).

  The input is the **last user message truncated** to
  `decision_context_chars` followed by a compact JSON of capability flags. No
  image parts, no tool results, no history: `DecisionsTranslator` rejects
  `input_image` parts on System One providers, and vision requirements are
  already enforced deterministically in Layer 1.

  ## Isolation and timeout

  The HTTP call runs in `Tokengate.Routing.DecisionTaskSupervisor` (falling
  back to an unlinked `Task` when the supervisor is not running, e.g. in a
  bare unit test) and is hard-killed after `decision_timeout_ms`. It never runs
  in the caller's process: the proxy holds `:tg_*` process-dictionary state for
  budget/billing and a classifier crash must not touch it.

  The result is metadata only — the engine returns `usage`, `latency_ms` and
  `source` so S3 can bill and persist the decision. This module never calls the
  decision model inside the request's budget path.
  """

  alias Tokengate.Proxy.Decisions

  @task_sup Tokengate.Routing.DecisionTaskSupervisor
  @default_timeout_ms 800
  @default_context_chars 1_200

  @type result :: %{
          use_case_key: String.t(),
          effort: String.t() | nil,
          confidence: float() | nil,
          effort_confidence: float() | nil,
          usage: map() | nil,
          latency_ms: non_neg_integer(),
          source: String.t(),
          model_id: String.t() | nil,
          probabilities: list()
        }

  @doc """
  Asks the decision model to classify `analysis` across `use_cases`.

  ## Options

    * `:post_fun` — the HTTP call, default `&Tokengate.Proxy.Decisions.post/4`.
    * `:lane_fun` — resolves the decision model's lane, default
      `&Tokengate.SmartRouter.resolve_decision_lane/1`.
    * `:timeout_ms` / `:context_chars` — defaults from the router config.
    * `:task_supervisor` — name of the `Task.Supervisor` (tests may omit it).
  """
  @spec classify(map(), map(), [map()], keyword()) :: {:ok, result()} | {:error, term()}
  def classify(decision_model, analysis, use_cases, opts \\ []) do
    with {:ok, lane} <- lane_for(decision_model, opts),
         {:ok, text} <- build_text(analysis, opts),
         {:ok, payload, parser} <- request(lane, analysis, use_cases, text),
         {:ok, body, latency_ms} <- post(lane, payload, opts) do
      with {:ok, answers} <- parser.(body) do
        parse(answers, analysis, use_cases, decision_model, body, latency_ms)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lane
  # ---------------------------------------------------------------------------

  defp lane_for(%{lane: %{} = lane}, _opts), do: {:ok, lane}

  defp lane_for(decision_model, opts) do
    lane_fun = Keyword.get(opts, :lane_fun, &Tokengate.SmartRouter.resolve_decision_lane/1)

    case decision_model do
      %{id: id} when is_binary(id) -> lane_fun.(id)
      id when is_binary(id) -> lane_fun.(id)
      _ -> {:error, :no_decision_model}
    end
  end

  # ---------------------------------------------------------------------------
  # Request
  # ---------------------------------------------------------------------------

  defp build_text(analysis, opts) do
    chars = Keyword.get(opts, :context_chars, @default_context_chars)

    if is_integer(chars) and chars > 0 do
      message = analysis.last_user_message || ""
      truncated = String.slice(message, 0, chars)

      metadata =
        Jason.encode!(%{
          "has_tools" => analysis.has_tools,
          "has_vision" => analysis.has_vision,
          "has_structured_output" => analysis.has_structured_output,
          "estimated_tokens" => analysis.prompt_tokens
        })

      {:ok, truncated <> "\n\n" <> metadata}
    else
      {:error, :invalid_context_chars}
    end
  end

  # The decision model has two wire shapes:
  #
  #   * `model_type: "decision"` (the default) — a choice-question envelope
  #     posted through `Decisions.post/4`.
  #   * `model_type: "llm"` — any chat model: one compact chat-completions call
  #     (`temperature: 0`, `max_tokens: 150`) told to answer with pure JSON.
  #
  # Both return `{payload, parser}`; the parser normalises the response into
  # the same `{"answers" => [...]}` shape `parse/6` already understands.
  defp request(lane, analysis, use_cases, text) do
    case value(lane, :model_type) do
      "llm" -> llm_request(lane, analysis, use_cases, text)
      _ -> decisions_request(lane, analysis, use_cases, text)
    end
  end

  defp decisions_request(lane, analysis, use_cases, text) do
    case payload(lane, analysis, use_cases, text) do
      %{} = payload -> {:ok, payload, &answers/1}
      nil -> {:error, :no_candidates}
    end
  end

  defp llm_request(lane, analysis, use_cases, text) do
    case Enum.reject(use_cases, &is_nil(value(&1, :key))) do
      [] ->
        {:error, :no_candidates}

      candidates ->
        payload = %{
          "model" => lane_provider_model(lane),
          "temperature" => 0,
          "max_tokens" => 150,
          "messages" => [
            %{"role" => "system", "content" => chat_system_prompt(candidates, analysis)},
            %{"role" => "user", "content" => text}
          ]
        }

        {:ok, payload, &chat_answers/1}
    end
  end

  # Descriptions and tags are the classifier's whole vocabulary: it can only
  # pick a key it was told about, in words it was given.
  defp chat_system_prompt(use_cases, analysis) do
    catalogue =
      Enum.map_join(use_cases, "\n", fn use_case ->
        "- #{value(use_case, :key)}: #{describe_use_case(use_case)}"
      end)

    effort_rule =
      if analysis.effort == nil do
        "Also pick \"effort\": one of \"low\" (trivial, fast answer), \"medium\" (normal work) " <>
          "or \"high\" (hard reasoning, architecture or debugging)."
      else
        "Do not include \"effort\": the client already declared it."
      end

    """
    You route one request to exactly one of the use cases below. Answer with \
    PURE JSON and nothing else:
    {"use_case": "<key>", "effort": "<low|medium|high>", "confidence": 0.0-1.0}

    #{effort_rule}

    Use cases:
    #{catalogue}
    """
  end

  defp chat_answers(body) do
    with {:ok, content} <- chat_content(body),
         {:ok, decoded} <- decode_json(content) do
      {:ok, chat_answers_from_json(decoded)}
    end
  end

  defp chat_content(body) do
    case Map.get(body, "choices") || Map.get(body, :choices) do
      [%{} = choice | _] ->
        case Map.get(choice, "message") || Map.get(choice, :message) do
          %{} = message ->
            case Map.get(message, "content") || Map.get(message, :content) do
              content when is_binary(content) -> {:ok, content}
              _ -> {:error, :invalid_response}
            end

          _ ->
            {:error, :invalid_response}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  # Models like to wrap JSON in a ```json fence; a fence is formatting, not an
  # answer, so it is stripped before decoding.
  defp decode_json(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```\z/, "")

    case Jason.decode(cleaned) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_response}
    end
  end

  defp chat_answers_from_json(decoded) do
    confidence = number(Map.get(decoded, "confidence"))

    use_case = %{
      "name" => "use_case",
      "choice" => Map.get(decoded, "use_case"),
      "confidence" => confidence
    }

    effort =
      case normalize_effort(Map.get(decoded, "effort")) do
        nil -> []
        value -> [%{"name" => "effort", "choice" => value, "confidence" => confidence}]
      end

    Enum.reject([use_case | effort], &is_nil(&1["choice"]))
  end

  defp payload(lane, analysis, use_cases, text) do
    case Enum.reject(use_cases, &is_nil(value(&1, :key))) do
      [] ->
        nil

      candidates ->
        questions =
          [use_case_question(candidates)] ++
            if(analysis.effort != nil, do: [], else: [effort_question()])

        %{
          "model" => lane_provider_model(lane),
          "input" => text,
          "questions" => questions
        }
    end
  end

  defp use_case_question(use_cases) do
    %{
      "name" => "use_case",
      "type" => "choice",
      "instructions" => "Pick the single use case that best matches the work the user asks for.",
      "choices" =>
        Enum.map(use_cases, fn use_case ->
          %{
            "value" => value(use_case, :key),
            "description" => describe_use_case(use_case)
          }
        end)
    }
  end

  defp describe_use_case(use_case) do
    description = value(use_case, :description) || value(use_case, :name) || ""
    tags = List.wrap(value(use_case, :tags))

    flags =
      [
        value(use_case, :requires_tools) && "requires tools",
        value(use_case, :requires_vision) && "requires vision",
        value(use_case, :requires_structured_output) && "requires structured output"
      ]
      |> Enum.reject(&is_nil/1)

    [description, if(tags != [], do: "tags: " <> Enum.join(tags, ", ")), Enum.join(flags, ", ")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  defp effort_question do
    %{
      "name" => "effort",
      "type" => "choice",
      "instructions" =>
        "How much reasoning effort does this request need? Pick low for trivial work, " <>
          "medium for everyday tasks and high for hard reasoning.",
      "choices" => [
        %{"value" => "low", "description" => "trivial, fast answer"},
        %{"value" => "medium", "description" => "normal work"},
        %{"value" => "high", "description" => "hard reasoning, architecture or debugging"}
      ]
    }
  end

  defp lane_provider_model(lane) do
    value(lane, :provider_model) || value(value(lane, :model_provider), :provider_model) ||
      "router"
  end

  # ---------------------------------------------------------------------------
  # Transport (isolated, timeout-bounded)
  # ---------------------------------------------------------------------------

  defp post(lane, payload, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    post_fun = Keyword.get(opts, :post_fun) || default_post(lane)

    provider = lane_provider(lane)
    credential = lane_credential(lane)
    start = System.monotonic_time(:millisecond)

    call = fn ->
      safely(fn -> post_fun.(provider, credential, payload, receive_timeout: timeout_ms) end)
    end

    result = run_bounded(call, timeout_ms, opts)

    latency_ms = System.monotonic_time(:millisecond) - start
    record_outcome(lane, result, opts)

    case result do
      {:ok, body} when is_map(body) -> {:ok, body, latency_ms}
      {:ok, body} -> {:error, {:invalid_response, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # An `llm` decision model speaks the chat-completions wire; a `decision` one
  # (or no `model_type` at all) speaks the decisions service.
  defp default_post(lane) do
    if value(lane, :model_type) == "llm" do
      &chat_post/4
    else
      &Decisions.post/4
    end
  end

  defp chat_post(provider, credential, payload, opts) do
    provider
    |> Tokengate.Proxy.ProviderAdapter.dispatch()
    |> then(& &1.chat_completion(provider, credential, payload, opts))
  end

  # The post_fun returns the 4-tuple the adapters speak; any exception inside
  # the task is converted to an error tuple so the linked fallback task does not
  # take the caller down with it.
  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp run_bounded(fun, timeout_ms, opts) do
    task = start_task(fun, opts)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, body, _latency, _headers}} -> {:ok, body}
      {:ok, {:error, :timeout, _status, _message}} -> {:error, :timeout}
      {:ok, {:error, reason, _status, message}} -> {:error, {reason, message}}
      {:ok, {:error, reason, _status}} -> {:error, reason}
      {:ok, {:ok, body}} -> {:ok, body}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:ok, other}
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp start_task(fun, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, @task_sup)

    if is_atom(supervisor) and Process.whereis(supervisor) != nil do
      Task.Supervisor.async_nolink(supervisor, fun)
    else
      Task.async(fun)
    end
  end

  defp record_outcome(lane, result, opts) do
    credential = lane_credential(lane)
    credential_id = credential && value(credential, :id)

    if is_binary(credential_id) do
      outcome_fun = Keyword.get(opts, :outcome_fun, &default_outcome/2)
      outcome_fun.(credential_id, outcome(result))
    end

    :ok
  rescue
    _ -> :ok
  end

  defp outcome({:ok, _body}), do: :success

  defp outcome({:error, :timeout}), do: {:failure, :timeout}

  defp outcome({:error, {reason, message}}) when is_atom(reason),
    do: {:failure, reason, message}

  defp outcome({:error, reason}) when is_atom(reason), do: {:failure, reason}

  defp outcome(_), do: {:failure, :server_error}

  defp default_outcome(credential_id, outcome) do
    case outcome do
      :success ->
        Tokengate.Routing.CircuitBreakerManager.record_success(credential_id)

      {:failure, reason, message} ->
        Tokengate.Routing.CircuitBreakerManager.record_failure(credential_id, reason, message)

      {:failure, reason} ->
        Tokengate.Routing.CircuitBreakerManager.record_failure(credential_id, reason)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Response
  # ---------------------------------------------------------------------------

  defp answers(%{"answers" => answers}) when is_list(answers) or is_map(answers),
    do: {:ok, answers}

  defp answers(%{answers: answers}) when is_list(answers) or is_map(answers),
    do: {:ok, answers}

  defp answers(_), do: {:error, :invalid_response}

  defp parse(answers, analysis, use_cases, decision_model, body, latency_ms) do
    with {:ok, use_case} <- choice_answer(answers, "use_case"),
         key when is_binary(key) <- use_case.value,
         true <- Enum.any?(use_cases, &(value(&1, :key) == key)) do
      effort =
        if analysis.effort != nil do
          analysis.effort
        else
          case choice_answer(answers, "effort") do
            {:ok, answer} -> normalize_effort(answer.value)
            {:error, _} -> nil
          end
        end

      {:ok,
       %{
         use_case_key: key,
         effort: effort,
         confidence: use_case.confidence,
         effort_confidence: effort_confidence(answers),
         usage: Map.get(body, "usage") || Map.get(body, :usage),
         latency_ms: latency_ms,
         source: "classifier",
         model_id: value(decision_model, :id),
         probabilities: use_case.probabilities
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown_use_case}
    end
  end

  defp effort_confidence(answers) do
    case choice_answer(answers, "effort") do
      {:ok, answer} -> answer.confidence
      {:error, _} -> nil
    end
  end

  defp normalize_effort(value) when value in ~w(low medium high), do: value
  defp normalize_effort(_), do: nil

  defp choice_answer(answers, name) do
    with %{} = answer <- answer_of(answers, name),
         choice when is_binary(choice) <- answer["choice"] || answer["value"] do
      {:ok,
       %{
         value: choice,
         confidence: confidence(answer),
         probabilities: probabilities(answer)
       }}
    else
      _ -> {:error, :missing_answer}
    end
  end

  defp answer_of(answers, name) when is_list(answers) do
    Enum.find(answers, fn
      %{} = answer -> Map.get(answer, "name") == name || Map.get(answer, :name) == name
      _ -> false
    end)
  end

  defp answer_of(answers, name) when is_map(answers) do
    Map.get(answers, name) || Map.get(answers, String.to_existing_atom(name))
  rescue
    ArgumentError -> Map.get(answers, name)
  end

  defp answer_of(_, _), do: nil

  # `confidence` is optional in the OpenAI Decisions shape: when the provider
  # omits it, the answer's own probability distribution carries the same
  # information, so the max probability stands in for it.
  defp confidence(answer) do
    case number(answer["confidence"]) do
      nil -> max_probability(probabilities(answer))
      value -> clamp(value)
    end
  end

  defp probabilities(answer) do
    case answer["probabilities"] do
      list when is_list(list) ->
        list
        |> Enum.map(fn
          %{} = entry -> {entry["value"], number(entry["probability"])}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      map when is_map(map) ->
        Enum.map(map, fn {value, probability} -> {value, number(probability)} end)
        |> Enum.reject(fn {_value, probability} -> is_nil(probability) end)

      _ ->
        []
    end
  end

  defp max_probability([]), do: nil

  defp max_probability(probabilities) do
    probabilities
    |> Enum.map(fn {_value, probability} -> probability end)
    |> Enum.max(fn -> nil end)
    |> clamp()
  end

  defp number(value) when is_number(value), do: value * 1.0
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(_), do: nil

  defp clamp(nil), do: nil
  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value

  # ---------------------------------------------------------------------------
  # Field access
  # ---------------------------------------------------------------------------

  defp value(%_{} = struct, key), do: Map.get(struct, key)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_, _), do: nil

  defp lane_provider(lane) do
    value(lane, :provider) || value(value(lane, :credential), :provider) ||
      value(value(lane, :model_provider), :provider)
  end

  defp lane_credential(lane) do
    value(lane, :credential) || value(value(lane, :model_provider), :credential)
  end
end
