defmodule Tokengate.Proxy.DecisionsTranslator do
  @moduledoc """
  OpenAI Decisions shape ⇄ TypeSafe System One shape.

  The gateway's public decisions surface is `POST /v1/decisions` — the OpenAI
  Decisions shape (`input` + an ordered `questions` list with `predicate`,
  `choice` and `score`). Providers that natively speak that shape (OpenAI,
  Fireworks, oMLX…) get the request verbatim. Providers that speak the
  System One shape (TypeSafe, OpenRouter, Cloudflare, and every Jev reseller)
  get it through this translator — ONE translation for all of them, because
  they all share the same envelope.

  The mapping, per the shapes both sides document:

    * `model` → `model`
    * `input` (string, or message items with `input_text`/`input_json`
      parts) → `state` (string, object, or array of `%{role, content}`)
    * `questions` array → map keyed by `name` (`q0`, `q1`… when absent)
      * `predicate` → `noul` (the true/false meanings ride the instructions)
      * `choice` (`choices: [{value, description}]`) → `choice` with
        `criteria: %{option => description | null}` — JSON object keys are
        strings, so a boolean/numeric `value` rides as its string form and
        `from_systemone/2` restores the original value on the way back
      * `score` (`levels: [{label, description}]`) → `score` with
        `criteria: [labels lowest first]`
    * answers back: System One keys a score by LEVEL INDEX and a choice by
      OPTION NAME, so `from_systemone/2` needs the original questions to
      restore the OpenAI shapes (`probabilities` as `[{value, probability}]`
      with the labels the client sent). A question the upstream did not
      answer stays missing (nil probability / empty list) — never an
      invented zero.
    * `usage` back: System One `{input_tokens, output_tokens}` → OpenAI
      `{input_tokens}` (decisions bill input only; output is free). When the
      upstream reports no usage at all, the key is OMITTED — the proxy's
      estimator prices the request instead of booking a fake $0.

  System One's `box` questions have no OpenAI counterpart: the public surface
  does not expose them. Image inputs (`input_image` parts) are rejected for
  System One providers in v1 — TypeSafe wants `assets` plus its danger-zone
  header, and OpenRouter's image handling is its own dialect; verbatim
  providers keep them untouched.
  """

  alias Tokengate.Proxy.OpenAIAdapter

  @typedoc "The original questions, in order, to restore the answer shapes."
  @type ctx :: %{
          required(:questions) => [
            %{
              required(:name) => String.t(),
              required(:type) => String.t(),
              required(:choices) => [map()],
              required(:levels) => [map()]
            }
          ]
        }

  @question_types ~w(predicate choice score)

  @doc """
  Validates the public request up front: the 400s a malformed body deserves,
  BEFORE any credential is picked, retried or logged. Returns `:ok` or
  `{:error, message}` (client-ready English, like the rest of the proxy's
  request-shape errors).
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{} = payload) do
    with :ok <- validate_input(payload["input"]),
         :ok <- validate_questions_shape(payload["questions"]) do
      validate_no_images(payload, questions_from(payload))
    end
  end

  @doc """
  The request for a System One provider, plus the ctx `from_systemone/2`
  needs to restore the OpenAI answer shapes. Assumes `validate/1` passed.
  """
  @spec to_systemone(map()) :: {:ok, map(), ctx()} | {:error, :bad_request, 400, String.t()}
  def to_systemone(%{} = payload) do
    questions = questions_from(payload)

    with {:ok, state} <- state_from_input(payload["input"]) do
      request = %{
        "model" => payload["model"],
        "state" => state,
        "questions" => question_map(questions)
      }

      ctx = %{
        questions:
          Enum.map(questions, fn q ->
            Map.take(q, [:name, :type, :choices, :levels])
          end)
      }

      {:ok, request, ctx}
    end
  end

  @doc """
  The System One response mapped onto the OpenAI Decisions shape, with the
  answers restored to the order (and the `name`s, and the score labels) of
  the original questions.
  """
  @spec from_systemone(map(), ctx()) :: map()
  def from_systemone(%{} = body, %{questions: questions} = _ctx) do
    answers = Map.get(body, "answers") || %{}

    response = %{"answers" => Enum.map(questions, &answer_of(answers, &1))}

    case Map.get(body, "usage") do
      usage when is_map(usage) ->
        Map.put(response, "usage", %{
          "input_tokens" => Map.get(usage, "input_tokens", 0),
          "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
        })

      _ ->
        response
    end
  end

  ## Validation ##############################################################

  defp validate_input(input) when is_binary(input) or is_list(input), do: :ok
  defp validate_input(_), do: {:error, "input is required (string or array)"}

  defp validate_questions_shape(questions) when is_list(questions) and questions != [] do
    questions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {q, index}, :ok ->
      case validate_question(q, index) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp validate_questions_shape(_), do: {:error, "questions must be a non-empty array"}

  defp validate_question(%{} = q, index) do
    type = q["type"]
    name = q["name"]

    cond do
      type not in @question_types ->
        {:error,
         "questions[#{index}].type must be one of: #{Enum.join(@question_types, ", ")} (got #{inspect(type)})"}

      name != nil and not is_binary(name) ->
        {:error, "questions[#{index}].name must be a string or omitted"}

      type == "choice" and not options?(q["choices"], "value") ->
        {:error, "questions[#{index}].choices must be a non-empty array of {value, description?}"}

      type == "score" and not options?(q["levels"], "label") ->
        {:error, "questions[#{index}].levels must be a non-empty array of {label, description?}"}

      true ->
        :ok
    end
  end

  defp validate_question(_other, index), do: {:error, "questions[#{index}] must be an object"}

  # choices/levels: lista no vacía de objetos con el campo escalar que
  # identifica la opción (value / label).
  defp options?(options, key) when is_list(options) and options != [] do
    Enum.all?(options, fn
      %{} = option -> scalar?(option[key])
      _ -> false
    end)
  end

  defp options?(_, _), do: false

  defp scalar?(value) when is_binary(value) or is_boolean(value) or is_number(value), do: true
  defp scalar?(_), do: false

  @image_reject_message ~s(input_image parts need a System One provider's asset flow: not supported on /v1/decisions for this provider yet)

  # Images are rejected for System One providers in v1: the shapes carry them
  # too differently (assets + danger-zone header).
  defp validate_no_images(payload, questions) do
    contents =
      [payload["input"] | Enum.map(questions, & &1.instructions)]
      |> Enum.flat_map(&List.wrap/1)

    if Enum.any?(contents, &has_image_part?/1) do
      {:error, @image_reject_message}
    else
      :ok
    end
  end

  defp has_image_part?(%{"type" => "input_image"}), do: true

  defp has_image_part?(%{"content" => parts}) when is_list(parts),
    do: Enum.any?(parts, &has_image_part?/1)

  defp has_image_part?(_), do: false

  ## Request #################################################################

  # The ordered questions, normalized: name (synthesized when absent), type
  # and the per-type payload the translation needs. Shapes already validated.
  defp questions_from(%{"questions" => questions} = _payload) when is_list(questions) do
    questions
    |> Enum.with_index()
    |> Enum.map(fn {q, index} -> normalize_question(q, index) end)
  end

  defp questions_from(_), do: []

  defp normalize_question(%{} = q, index) do
    %{
      name: q["name"] || "q#{index}",
      type: q["type"],
      instructions: q["instructions"],
      choices: List.wrap(q["choices"]),
      levels: List.wrap(q["levels"])
    }
  end

  # The questions map: the id the caller picks is the name.
  defp question_map(questions) do
    Map.new(questions, fn
      %{type: "predicate"} = q ->
        {q.name, %{"type" => "noul", "instructions" => content_of(q.instructions)}}

      %{type: "choice"} = q ->
        criteria =
          Map.new(q.choices, fn choice -> {to_string(choice["value"]), choice["description"]} end)

        {q.name,
         %{
           "type" => "choice",
           "instructions" => content_of(q.instructions),
           "criteria" => criteria
         }}

      %{type: "score"} = q ->
        labels = Enum.map(q.levels, & &1["label"])

        {q.name,
         %{"type" => "score", "instructions" => content_of(q.instructions), "criteria" => labels}}
    end)
  end

  # `input` → `state`. A string goes as-is; message items become role/content
  # pairs (TypeSafe's documented chat-log-like state); an `input_json` part
  # contributes its decoded JSON value.
  defp state_from_input(input) when is_binary(input), do: {:ok, input}

  defp state_from_input(input) when is_list(input) do
    state =
      Enum.map(input, fn
        %{} = item when is_map_key(item, "role") ->
          %{"role" => item["role"], "content" => parts_content(item["content"])}

        %{"type" => "input_json", "json" => json} ->
          json

        other ->
          other
      end)

    {:ok, state}
  end

  defp state_from_input(_), do: {:error, :bad_request, 400, "input is required (string or array)"}

  defp parts_content(content) when is_binary(content), do: content

  defp parts_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      %{"type" => "input_json", "json" => json} -> Jason.encode!(json)
      %{"type" => "input_image"} -> nil
      other -> other
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [only] -> only
      parts -> Enum.join(parts, "\n")
    end
  end

  defp parts_content(other), do: other

  # Images were validated up-front (validate/1), so a parts list here can
  # only carry text and JSON.
  defp content_of(parts) when is_list(parts), do: parts_content(parts)

  defp content_of(other), do: other

  ## Response ###############################################################

  # System One answers keyed by the question id → OpenAI answers array in the
  # original order. A score's probabilities/legend are keyed by level INDEX;
  # the labels of the original levels restore the OpenAI `value`s. A missing
  # answer stays missing (nil probability / empty list) — never an invented
  # zero.
  defp answer_of(answers, %{name: name, type: type} = question) do
    answer = Map.get(answers, name) || %{}

    case to_string(type) do
      "predicate" ->
        %{"type" => "predicate", "name" => name, "probability" => Map.get(answer, "noul")}

      "choice" ->
        %{
          "type" => "choice",
          "name" => name,
          "choice" => restore_value(Map.get(answer, "choice"), question),
          "probabilities" => choice_probabilities(answer, question),
          "confidence" => Map.get(answer, "confidence")
        }

      "score" ->
        %{
          "type" => "score",
          "name" => name,
          "score" => Map.get(answer, "score"),
          "probabilities" => score_probabilities(answer, question),
          "confidence" => Map.get(answer, "confidence")
        }
    end
  end

  # System One keys a choice's answer by the option's STRING form (JSON
  # object key); the OpenAI shape wants the value the client sent — a string
  # comes back as-is, a boolean/numeric value is restored from the ctx.
  defp restore_value(choice, %{choices: choices}) when is_binary(choice) do
    case Enum.find(choices, fn c -> is_map(c) and to_string(c["value"]) == choice end) do
      %{} = original -> original["value"]
      _ -> choice
    end
  end

  defp restore_value(choice, _question), do: choice

  defp choice_probabilities(answer, %{choices: choices}) do
    probabilities = Map.get(answer, "probabilities") || %{}

    Enum.map(probabilities, fn {key, probability} ->
      original = Enum.find(choices, fn c -> is_map(c) and to_string(c["value"]) == key end)

      %{"value" => (original && original["value"]) || key, "probability" => probability}
    end)
  end

  # System One keys a score's probabilities by level index ("0", "1"…); the
  # OpenAI shape keys them by the level label the client sent. Sorted by
  # index: a map's iteration order is not a contract (12 levels would read
  # "1", "10", "11", "2"…).
  defp score_probabilities(answer, %{levels: levels}) do
    labels = Enum.map(levels, & &1["label"])
    probabilities = Map.get(answer, "probabilities") || %{}

    probabilities
    |> Enum.sort_by(fn {index, _} -> Integer.parse(to_string(index)) end)
    |> Enum.map(fn {index, probability} ->
      %{"value" => level_label(labels, index), "probability" => probability}
    end)
  end

  defp level_label(labels, index) do
    case Integer.parse(to_string(index)) do
      {i, ""} -> Enum.at(labels, i) || to_string(index)
      _ -> to_string(index)
    end
  end

  ## Shared post #############################################################

  @doc false
  # The upstream call for a System One provider: translate, POST to the path
  # `ProviderPaths` resolves for :decisions (the catalog pins TypeSafe's to
  # /systemone, OpenRouter's to its absolute alpha URL), translate back.
  def post_systemone(provider, credential, payload, opts) do
    case validate(payload) do
      :ok ->
        case to_systemone(payload) do
          {:ok, systemone_payload, ctx} ->
            case OpenAIAdapter.service_post(
                   provider,
                   credential,
                   :decisions,
                   systemone_payload,
                   opts
                 ) do
              {:ok, body, latency, headers} -> {:ok, from_systemone(body, ctx), latency, headers}
              error -> error
            end

          error ->
            error
        end

      # El controller ya validó; este 400 sólo se ve si alguien llama al
      # traductor por su cuenta.
      {:error, message} ->
        {:error, :bad_request, 400, message}
    end
  end
end
