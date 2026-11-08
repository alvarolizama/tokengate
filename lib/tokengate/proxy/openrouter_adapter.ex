defmodule Tokengate.Proxy.OpenRouterAdapter do
  @moduledoc """
  OpenRouter dialect adapter.

  OpenRouter speaks the OpenAI-compatible surface for chat, embeddings and
  the path-routed services, with one deviation this adapter owns: embedding
  models are listed at `{base_url}/embeddings/models` instead of
  `{base_url}/models`.

  Everything else is delegated to `OpenAIAdapter` untouched.
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

  # Su catálogo por servicio es la MISMA consulta sobre /models con la modalidad
  # de salida como filtro (`?output_modalities=image`), así que comparte motor.
  @impl true
  defdelegate list_service_models(provider, credential, endpoint), to: OpenAIAdapter

  @impl true
  def service_post(provider, credential, service, payload, opts) do
    OpenAIAdapter.service_post(provider, credential, service, payload, opts)
  end
end
