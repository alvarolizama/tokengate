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
          | :connection_error
          | :auth_error

  @type chat_result ::
          {:ok, body :: map(), latency_ms :: non_neg_integer()}
          | {:error, failure_reason(), status :: non_neg_integer() | nil}

  @doc """
  Sends a non-streaming chat completion request to the provider.

  Returns `{:ok, decoded_body, latency_ms}` on a 2xx response, or
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
      stream process exits with a non-normal reason shortly after.

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
  Classifies an HTTP status code into a failure reason.

    * `401`, `402`, `403` -> `:auth_error` (credential is bad — disable it
      permanently and fall back to the next provider).
    * `429`, `529` -> `:rate_limited` (cooldown 10 min, fall back).
    * other `4xx` -> `:client_error` (caller's fault — surface, don't switch).
    * `5xx` -> `:server_error` (cooldown 30 min, fall back).

  `nil` (no status, e.g. transport failure) is not a status and is not
  classified here — see `classify_error/1`.
  """
  @spec classify_status(non_neg_integer()) :: failure_reason()
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

  `adapter` may be a module (returned as-is), an atom name, a string name,
  or `nil`. The OpenAI-compatible API is the lingua franca, so every known
  name ("openai", "openai-compatible") and every unknown name alike map to
  `Tokengate.Proxy.OpenAIAdapter`.

  A provider map with no `:adapter` / `:name` field also defaults to
  `OpenAIAdapter`.
  """
  @spec dispatch(atom() | String.t() | map() | nil) :: module()
  def dispatch(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module), do: module, else: resolve(nil)
  end

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
