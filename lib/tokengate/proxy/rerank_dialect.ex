defmodule Tokengate.Proxy.RerankDialect do
  @moduledoc """
  Resolves the rerank payload/response format for a provider.

  TokenGate's rerank proxy speaks the Cohere shape (`query`, `documents`,
  optional `top_n` / `return_documents`) as its lingua franca — the same
  surface served natively by oMLX, Fireworks and LiteLLM. Some providers
  (DashScope) expose rerank only through a different, nested dialect, so
  the adapter translates the payload before sending and the response after
  receiving.

  Dialects are resolved from provider data (the `rerank_dialect` field),
  never from hardcoded name checks in the hot path. Adding a new dialect
  means registering its encode/decode pair here.

  ## Dialects

    * `"cohere"` — passthrough. The payload is forwarded exactly as received
      and the response is used as-is (the controller still normalizes
      `data` → `results` for Jina-style backends).
    * `"dashscope"` — DashScope native: request wrapped in
      `input.query` / `input.documents` / `parameters`, response unwrapped
      from `output.results`.
  """

  alias Tokengate.Proxy.DashScopeRerank

  @type dialect :: :passthrough | {encode_fun, decode_fun}
  @type encode_fun :: (map() -> map())
  @type decode_fun :: (map() -> map())

  @doc """
  Returns the dialect behaviour for a provider map or struct.

  `:passthrough` means the standard Cohere format is used unchanged.
  A `{encode, decode}` tuple means the payload is translated before sending
  and the response translated back to the Cohere shape.
  """
  @spec dialect_for(map() | nil) :: dialect()
  def dialect_for(provider) when is_map(provider) do
    case Map.get(provider, :rerank_dialect) || Map.get(provider, "rerank_dialect") do
      "dashscope" -> {&DashScopeRerank.encode/1, &DashScopeRerank.decode/1}
      _ -> :passthrough
    end
  end

  def dialect_for(_), do: :passthrough
end
