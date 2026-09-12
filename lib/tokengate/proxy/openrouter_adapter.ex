defmodule Tokengate.Proxy.OpenRouterAdapter do
  @moduledoc """
  OpenRouter dialect adapter.

  OpenRouter speaks the OpenAI-compatible surface for chat and
  embeddings, with a single deviation: its embedding models are listed at
  `{base_url}/embeddings/models` instead of `{base_url}/models`. This
  adapter delegates everything to `OpenAIAdapter` and only overrides the
  embedding model listing.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter

  alias Tokengate.Proxy.OpenAIAdapter

  @impl true
  defdelegate chat_completion(provider, credential, payload, opts \\ []),
    to: OpenAIAdapter

  @impl true
  defdelegate stream_chat_completion(provider, credential, payload, opts \\ []),
    to: OpenAIAdapter

  @impl true
  defdelegate health_check(provider, credential), to: OpenAIAdapter

  @impl true
  defdelegate embeddings(provider, credential, payload, opts \\ []), to: OpenAIAdapter

  @impl true
  def list_embedding_models(provider, credential) do
    # OpenRouter lists its embedding catalogue at /embeddings/models.
    OpenAIAdapter.list_models_at(provider, credential, "/embeddings/models")
  end
end
