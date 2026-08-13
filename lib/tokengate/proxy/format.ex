defmodule Tokengate.Proxy.Format do
  @moduledoc """
  Resolves the translation dialect for a provider, per service.

  TokenGate speaks a standard format to its clients (OpenAI for chat and
  embeddings, Cohere for rerank). Some providers (DashScope / Qwen Cloud)
  speak a native format for a given service, so the adapter translates the
  payload before sending and the response after receiving.

  Dialects are resolved from provider data (`embedding_format` /
  `rerank_format`), never from hardcoded name checks in the hot path. Adding
  a new dialect means registering its encode/decode pair here.
  """

  alias Tokengate.Proxy.{DashScopeEmbedding, DashScopeRerank}

  @type dialect :: :passthrough | {encode_fun, decode_fun}
  @type encode_fun :: (map() -> map())
  @type decode_fun :: (map() -> map())

  @doc "Resolves the embeddings dialect for a provider map or struct."
  @spec embedding_dialect_for(map() | nil) :: dialect()
  def embedding_dialect_for(provider) do
    case format(provider, :embedding_format) do
      "dashscope" -> {&DashScopeEmbedding.encode/1, &DashScopeEmbedding.decode/1}
      _ -> :passthrough
    end
  end

  @doc "Resolves the rerank dialect for a provider map or struct."
  @spec rerank_dialect_for(map() | nil) :: dialect()
  def rerank_dialect_for(provider) do
    case format(provider, :rerank_format) do
      "dashscope" -> {&DashScopeRerank.encode/1, &DashScopeRerank.decode/1}
      _ -> :passthrough
    end
  end

  defp format(provider, field) when is_map(provider) do
    Map.get(provider, field) || Map.get(provider, Atom.to_string(field))
  end

  defp format(_, _), do: nil
end
