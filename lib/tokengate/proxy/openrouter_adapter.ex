defmodule Tokengate.Proxy.OpenRouterAdapter do
  @moduledoc """
  OpenRouter dialect adapter.

  OpenRouter speaks the OpenAI-compatible surface for chat, embeddings and the
  path-routed services, with two deviations this adapter owns:

    * embedding models are listed at `{base_url}/embeddings/models` instead of
      `{base_url}/models`;
    * its transcription endpoint only accepts `json` and `verbose_json` as
      `response_format` — `text`, `srt` and `vtt` are rejected with a `400`
      (OpenRouter's own docs). Helmcode and NaN accept those three, so the same
      client body works in one provider and fails in the other. When the client
      asks for plain text, this adapter asks the upstream for `json` and hands
      the transcript back as `text/plain`.

  Everything else is delegated to `OpenAIAdapter` untouched.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Proxy.AudioMultipart
  alias Tokengate.Proxy.OpenAIAdapter
  alias Tokengate.Proxy.RawResponse

  # The one format this endpoint cannot serve that the other STT providers can.
  @plain_text "text"

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
  def service_post(provider, credential, :stt, payload, opts) do
    if Map.get(payload, "response_format") == @plain_text do
      post_plain_text(provider, credential, payload, opts)
    else
      OpenAIAdapter.service_post(provider, credential, :stt, payload, opts)
    end
  end

  def service_post(provider, credential, service, payload, opts) do
    OpenAIAdapter.service_post(provider, credential, service, payload, opts)
  end

  # Ask for `json` (the format the endpoint does serve) and answer the client with
  # the transcript alone, in the shape it requested.
  defp post_plain_text(provider, credential, payload, opts) do
    {payload, opts} = force_json_format(payload, opts)

    case OpenAIAdapter.service_post(provider, credential, :stt, payload, opts) do
      {:ok, %{"text" => text}, latency, headers} when is_binary(text) ->
        {:ok, %RawResponse{body: text, content_type: "text/plain; charset=utf-8"}, latency,
         headers}

      other ->
        other
    end
  end

  # A multipart body carries the format in its own part (the client's own bytes
  # are preserved); a JSON request only needs the field replaced before it is
  # encoded.
  defp force_json_format(payload, opts) do
    case Keyword.get(opts, :raw_body) do
      raw when is_binary(raw) ->
        {body, content_type} =
          AudioMultipart.rewrite_field(
            raw,
            Keyword.get(opts, :content_type),
            "response_format",
            "json"
          )

        {payload, Keyword.merge(opts, raw_body: body, content_type: content_type)}

      _ ->
        {Map.put(payload, "response_format", "json"), opts}
    end
  end
end
