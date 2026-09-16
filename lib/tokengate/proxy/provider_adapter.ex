defmodule Tokengate.Proxy.ProviderAdapter do
  @moduledoc """
  Behaviour for upstream LLM provider adapters.

  TokenGate speaks the OpenAI-compatible API shape (`/chat/completions`,
  `/models`) as its lingua franca. Every provider — OpenAI itself or any
  OpenAI-compatible endpoint — is reached through an adapter implementing
  this behaviour. The provider's `base_url` must include the full API base
  path (e.g. `https://api.openai.com/v1`, `https://openrouter.ai/api/v1`);
  the adapter only appends the final endpoint segment. Today only `Tokengate.Proxy.OpenAIAdapter` exists; unknown
  adapter names fall back to it, because the OpenAI-compatible surface is
  the contract every upstream is expected to honour.

  Adapters are responsible for:

    * transparently forwarding the request payload to the upstream — no added
      system prompts, no modified messages, no stripped or injected fields;
    * classifying HTTP and transport errors into failure reasons so the
      circuit breaker and budget machinery can react uniformly;
    * exposing a non-streaming `chat_completion/4`, a streaming
      `stream_chat_completion/4` (SSE), and a `health_check/2`.

  ## Error classification

  The `failure_reason` type is the small set of atoms the rest of TokenGate
  reasons about. Adapters translate provider-specific status codes and
  transport errors into one of these via `classify_status/1` and
  `classify_error/1`.

  ## Shared classification helpers

  `classify_status/1` and `classify_error/1` are module-level functions
  (not callbacks) usable by any adapter implementation and directly testable.
  `dispatch/1` resolves the adapter module for a given provider.
  """

  @type failure_reason ::
          :timeout
          | :server_error
          | :rate_limited
          | :client_error
          | :bad_request
          | :connection_error
          | :auth_error

  @type chat_result ::
          {:ok, body :: map(), latency_ms :: non_neg_integer(),
           resp_headers :: [{String.t(), String.t()}]}
          | {:error, failure_reason(), status :: non_neg_integer() | nil}

  @doc """
  Sends a non-streaming chat completion request to the provider.

  Returns `{:ok, decoded_body, latency_ms, resp_headers}` on a 2xx response, or
  `{:error, failure_reason, status}` on any failure (non-2xx status,
  timeout, or transport error with `status` set to `nil`).
  """
  @callback chat_completion(
              provider :: map(),
              credential :: map(),
              payload :: map(),
              opts :: keyword()
            ) :: chat_result()

  @doc """
  Starts a streaming chat completion request against the provider.

  Returns `{:ok, pid}` where `pid` is a dedicated process that streams the
  upstream SSE response to the caller. The caller monitors `pid` and
  receives:

    * `{:sse_chunk, binary}` — a raw SSE data payload (the JSON string,
      without the `data: ` prefix). Heartbeats and comments are skipped.
    * `{:sse_done}` — the upstream sent `data: [DONE]`. The stream process
      exits `:normal` immediately after.
    * `{:sse_error, term}` — a transport or parsing failure occurred. The
      stream process ends shortly after.

  First-token and overall stream timeouts are the caller's responsibility,
  not the adapter's.
  """
  @callback stream_chat_completion(
              provider :: map(),
              credential :: map(),
              payload :: map(),
              opts :: keyword()
            ) :: {:ok, pid()} | {:error, failure_reason(), status :: non_neg_integer() | nil}

  @doc """
  Health-checks the provider by hitting its models endpoint.

  Returns `:ok` on a 2xx, or `{:error, failure_reason}` otherwise.
  """
  @callback health_check(provider :: map(), credential :: map()) ::
              :ok | {:error, failure_reason()}

  @doc """
  Generates embeddings via the provider's `/embeddings` endpoint
  (derived from the single `base_url`). The gateway's contract is the
  OpenAI embeddings shape — the adapter translates request and response
  when the provider's dialect needs it.

  Returns the same 4-tuple shape as `chat_completion/4`.
  """
  @callback embeddings(
              provider :: map(),
              credential :: map(),
              payload :: map(),
              opts :: keyword()
            ) ::
              {:ok, body :: map(), latency_ms :: non_neg_integer(),
               resp_headers :: [{String.t(), String.t()}]}
              | {:error, failure_reason(), status :: non_neg_integer() | nil,
                 error_message :: String.t() | nil}

  @doc """
  Posts a passthrough request to one of the provider's non-chat services —
  `:rerank`, `:stt`, `:tts`, `:image`, `:video`, `:music`.

  The URL is `base_url` + the path the service resolves to (the
  `ProviderPaths` vocabulary: operator override, then catalog hardcode,
  then the generic OpenAI-compatible default). Payload and response are
  forwarded untouched, like `embeddings/4`; cost/usage normalization is
  the caller's, since the shapes differ per service.

  `opts` may carry `:raw_body` + `:content_type`: the request is then sent
  byte-for-byte with the client's own content-type instead of JSON-encoded
  (the multipart stt body cannot be rebuilt), and a non-JSON 2xx response
  is returned as a `Tokengate.Proxy.RawResponse` instead of a decoded map.

  Returns the same 4-tuple shape as `embeddings/4`.
  """
  @callback service_post(
              provider :: map(),
              credential :: map(),
              service :: atom(),
              payload :: map(),
              opts :: keyword()
            ) ::
              {:ok, body :: map() | Tokengate.Proxy.RawResponse.t(),
               latency_ms :: non_neg_integer(), resp_headers :: [{String.t(), String.t()}]}
              | {:error, failure_reason(), status :: non_neg_integer() | nil,
                 error_message :: String.t() | nil}

  @doc """
  Lists the model ids the provider exposes for embeddings. Dialects vary:
  OpenAI-compatible exposes them under `/models`, OpenRouter under
  `/embeddings/models`. Returns `{:ok, [model_id]}` or `{:error, reason}`.
  """
  @callback list_embedding_models(provider :: map(), credential :: map()) ::
              {:ok, [String.t()]} | {:error, failure_reason()}

  @doc """
  Classifies an HTTP status code into a failure reason.

    * `400` -> `:bad_request` (the provider rejected *this* body for its own
      reasons: an unsupported field or parameter, a limit only that model
      enforces, a prefix over its context window…). The same body can be
      accepted by the next candidate, so the request falls back to it — and
      the rejection carries no consequence for the credential that issued it:
      the breaker never counts it and the credential is never deactivated.
    * `401`, `402`, `403` -> `:auth_error` (credential is bad — disable it
      permanently and fall back to the next provider).
    * `429`, `529` -> `:rate_limited` (selects the short rate-limit cooldown
      of the circuit breaker, then falls back).
    * other `4xx` -> `:client_error` (caller's fault and, unlike `400`, not
      provider-specific: `404`/`422`/… are surfaced, not retried elsewhere).
    * `5xx` -> `:server_error` (selects the standard circuit-breaker cooldown,
      then falls back).

  `nil` (no status, e.g. transport failure) is not a status and is not
  classified here — see `classify_error/1`.
  """
  @spec classify_status(non_neg_integer()) :: failure_reason()
  def classify_status(400), do: :bad_request
  def classify_status(status) when status in [401, 402, 403], do: :auth_error
  def classify_status(status) when status in [429, 529], do: :rate_limited
  def classify_status(status) when status >= 400 and status < 500, do: :client_error
  def classify_status(status) when status >= 500 and status < 600, do: :server_error

  @doc """
  Classifies a transport or Finch error into a failure reason.

  Timeout-related reasons map to `:timeout`; everything else (connection
  refused, DNS failure, TLS error, etc.) maps to `:connection_error`.
  Handles `Mint.TransportError`, `Finch.TransportError`, `Finch.Error`
  (whose `reason` may be `:request_timeout`), and bare atoms/tuples.
  """
  @spec classify_error(term()) :: failure_reason()
  def classify_error(%Mint.TransportError{reason: reason}), do: classify_reason(reason)
  def classify_error(%Finch.TransportError{reason: reason}), do: classify_reason(reason)
  def classify_error(%Finch.Error{reason: reason}), do: classify_reason(reason)

  def classify_error({:transport_error, reason}), do: classify_reason(reason)
  def classify_error(reason) when is_atom(reason), do: classify_reason(reason)
  def classify_error(_other), do: :connection_error

  @timeout_reasons [:timeout, :timeout_value, :connect_timeout, :handshake_timeout]

  defp classify_reason(reason) when reason in @timeout_reasons, do: :timeout
  defp classify_reason(:request_timeout), do: :timeout
  defp classify_reason(_reason), do: :connection_error

  @doc """
  Resolves the adapter module for a provider.

  Resolution order: an explicit `:dialect` field on the provider map wins
  (`"openrouter"` → `OpenRouterAdapter`, `"openai"` → `OpenAIAdapter`);
  everything else — module atoms, `adapter`/`name` strings, nil — falls
  back through the legacy name-based resolution to `OpenAIAdapter`, the
  lingua franca.
  """
  @spec dispatch(atom() | String.t() | map() | nil) :: module()
  def dispatch(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module), do: module, else: resolve(nil)
  end

  def dispatch(%{dialect: "openrouter"}), do: Tokengate.Proxy.OpenRouterAdapter
  def dispatch(%{dialect: "openai"}), do: Tokengate.Proxy.OpenAIAdapter
  def dispatch(%{"dialect" => "openrouter"}), do: Tokengate.Proxy.OpenRouterAdapter
  def dispatch(%{"dialect" => "openai"}), do: Tokengate.Proxy.OpenAIAdapter

  def dispatch(%{adapter: adapter}) when is_binary(adapter), do: resolve(adapter)

  def dispatch(%{adapter: adapter}) when is_atom(adapter) and not is_nil(adapter),
    do: resolve(adapter)

  def dispatch(%{name: name}) when is_binary(name), do: resolve(name)
  def dispatch(name) when is_binary(name), do: resolve(name)
  def dispatch(_), do: Tokengate.Proxy.OpenAIAdapter

  defp resolve("openai"), do: Tokengate.Proxy.OpenAIAdapter
  defp resolve("openai-compatible"), do: Tokengate.Proxy.OpenAIAdapter
  defp resolve("OpenAI"), do: Tokengate.Proxy.OpenAIAdapter
  defp resolve(:openai), do: Tokengate.Proxy.OpenAIAdapter
  defp resolve(:openai_compatible), do: Tokengate.Proxy.OpenAIAdapter
  defp resolve(_), do: Tokengate.Proxy.OpenAIAdapter
end
