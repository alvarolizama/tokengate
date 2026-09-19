defmodule Tokengate.Proxy.TypeSafeAdapter do
  @moduledoc """
  TypeSafe (typesafe.ai) dialect adapter — Jev, the first System One model.

  TypeSafe's surface is NOT OpenAI-compatible:

      POST {base_url}/systemone
      %{state: ..., model: ..., questions: %{id => %{type, instructions, criteria}}}
      → %{model: ..., answers: %{id => %{type, ...}}, usage: %{input_tokens, output_tokens}}

  The gateway's lingua franca is chat/completions, so this adapter maps a chat
  request onto a System One evaluation:

    * **state** — the conversation's messages, serialized as an array of
      `%{role, content}` maps (TypeSafe accepts arrays of structured text).
    * **model** — rewritten to the `provider_model` id upstream, same as any
      dialect.
    * **questions** — the operator's fixed question set, carried verbatim in
      the model_provider's `extra_body["questions"]` (protected body keys do
      not include it). Without a question set the request is rejected: there
      is no honest chat translation of "generate text" for a decision model.
    * **answers → choices** — each answer is serialized into the assistant
      message content (a JSON object string), and the full typed payload
      rides `systemone` on the response body for clients that read it.

  Usage: TypeSafe reports `usage.input_tokens`/`output_tokens` (no cached
  split, output is free); the response keeps it for `UsageNormalizer`-driven
  cost accounting, which prices it from the model_provider's manual prices.

  No SSE upstream: `stream_chat_completion` performs the single request and
  emits it as one chunk + DONE, so streaming clients still work.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Proxy.OpenAIAdapter

  @systemone_path_key :chat

  @impl true
  def chat_completion(provider, credential, payload, opts \\ []) do
    case to_systemone(payload) do
      {:ok, systemone_payload} ->
        path = service_path(provider)

        case OpenAIAdapter.post_json_with_headers(
               provider,
               credential,
               path,
               systemone_payload,
               [],
               opts
             ) do
          {:ok, body, latency, headers} -> {:ok, from_systemone(body), latency, headers}
          {:error, reason, status, _message} -> {:error, reason, status}
        end

      {:error, reason, status, _message} ->
        {:error, reason, status}
    end
  end

  @impl true
  def stream_chat_completion(provider, credential, payload, opts \\ []) do
    caller = self()

    # TypeSafe has no SSE surface: evaluate once in the spawned process and
    # emit a single chunk + DONE, mirroring OpenAIAdapter's stream contract
    # ({:sse_chunk, binary}, {:sse_done}, normal exit) so the proxy's
    # streaming path is unchanged.
    case to_systemone(payload) do
      {:ok, systemone_payload} ->
        path = service_path(provider)

        {:ok,
         Task.start(fn ->
           result =
             OpenAIAdapter.post_json_with_headers(
               provider,
               credential,
               path,
               systemone_payload,
               [],
               opts
             )

           case result do
             {:ok, body, _latency, _headers} ->
               translated = from_systemone(body)

               chunk = %{
                 "id" => Map.get(translated, "id"),
                 "object" => "chat.completion.chunk",
                 "model" => Map.get(translated, "model"),
                 "choices" => [
                   %{
                     "index" => 0,
                     "delta" => %{"role" => "assistant", "content" => content_of(translated)},
                     "finish_reason" => nil
                   }
                 ]
               }

               send(caller, {:sse_chunk, Jason.encode!(chunk)})
               send(caller, {:sse_done})

             {:error, reason, status, _message} ->
               send(caller, {:sse_error, {reason, status, nil}})
           end
         end)}

      {:error, reason, status, message} ->
        {:error, reason, status, message}
    end
  end

  @impl true
  def health_check(provider, credential), do: OpenAIAdapter.health_check(provider, credential)

  @impl true
  def embeddings(_provider, _credential, _payload, _opts \\ []) do
    {:error, :bad_request, 400, "TypeSafe has no embeddings surface"}
  end

  @impl true
  def list_embedding_models(_provider, _credential), do: {:error, :bad_request}

  # TypeSafe sirve SÓLO el endpoint de decisiones: no publica catálogo por
  # servicio, y `ServiceModels.discovery/2` no tiene entrada suya.
  @impl true
  def list_service_models(_provider, _credential, _endpoint), do: {:error, :bad_request}

  @impl true
  def service_post(_provider, _credential, _service, _payload, _opts) do
    {:error, :bad_request, 400, "TypeSafe serves no media services"}
  end

  ## Translation ################################################################

  @doc """
  Builds the System One request body from a chat payload.

  The question set comes from the model_provider's `extra_body` — the proxy
  merges extra_body keys into the payload before the adapter sees it (see
  `apply_request_overrides`), so the questions ride `payload["questions"]`.
  A request without questions cannot be translated: a System One model
  evaluates questions, it does not generate free-form text.
  """
  @spec to_systemone(map()) :: {:ok, map()} | {:error, :bad_request, 400, String.t()}
  def to_systemone(payload) when is_map(payload) do
    questions = Map.get(payload, "questions")

    if is_map(questions) and map_size(questions) > 0 do
      {:ok,
       %{
         "state" => state_from_messages(Map.get(payload, "messages")),
         "model" => Map.get(payload, "model"),
         "questions" => questions
       }}
    else
      {:error, :bad_request, 400,
       "TypeSafe requests need a question set: set extra_body {\"questions\": ...} on the model provider"}
    end
  end

  # The conversation becomes the state, verbatim: role/content pairs are the
  # structured text TypeSafe documents for chat-log-like state.
  defp state_from_messages(messages) when is_list(messages), do: messages
  defp state_from_messages(other) when is_binary(other), do: other
  defp state_from_messages(_), do: ""

  @doc """
  Maps a System One response onto the OpenAI chat completion shape the rest
  of the pipeline consumes.

  The assistant content is the JSON-encoded answers map (a single decision
  object when there is one question), and the typed payload rides the
  `systemone` key for direct consumption. `usage` is renamed to the OpenAI
  counters so `UsageNormalizer` and cost accounting see what they expect.
  """
  @spec from_systemone(map()) :: map()
  def from_systemone(%{} = body) do
    answers = Map.get(body, "answers") || %{}
    usage = Map.get(body, "usage") || %{}

    %{
      "id" => "systemone-" <> (Map.get(body, "request_id") || generate_id()),
      "object" => "chat.completion",
      "model" => Map.get(body, "model"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => Jason.encode!(answers)},
          "finish_reason" => "stop"
        }
      ],
      "systemone" => %{"answers" => answers},
      "usage" => %{
        "prompt_tokens" => Map.get(usage, "input_tokens", 0),
        "completion_tokens" => Map.get(usage, "output_tokens", 0)
      }
    }
  end

  defp content_of(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp content_of(_), do: ""

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # The chat path the catalog override pins (`paths: %{chat: "/systemone"}`),
  # with the operator's own path_overrides still winning.
  defp service_path(provider) do
    Tokengate.Providers.ProviderPaths.resolve(provider, @systemone_path_key) ||
      "/systemone"
  end
end
