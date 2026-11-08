defmodule Tokengate.Proxy.DashScopeAdapter do
  @moduledoc """
  DashScope (Alibaba Model Studio / Qwen Cloud) dialect adapter.

  DashScope exposes a SPLIT surface:

    * **compatible-mode/v1** — OpenAI-compatible chat, models, embeddings
      and image (`/images/generations`, qwen-image). Delegated to
      `OpenAIAdapter` untouched (default paths).
    * **NATIVE services** this adapter translates:
        * **stt** (qwen3-asr-flash): OpenAI-compatible but rides
          `/chat/completions` with an `input_audio` content block; the
          transcribed text comes back as the assistant message.
        * **tts** (qwen3-tts / cosyvoice): native
          `/api/v1/services/aigc/multimodal-generation/generation`, sync,
          answers `output.audio.url`.

  The native services live under the `/api/v1` segment of the same host as
  base_url, which is why the paths here are ABSOLUTE URLs derived from the
  provider's host.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Proxy.OpenAIAdapter

  @native_base_path "/api/v1"
  @tts_path @native_base_path <> "/services/aigc/multimodal-generation/generation"

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
  defdelegate list_embedding_models(provider, credential), to: OpenAIAdapter

  # DashScope no publica catálogo por servicio: `ServiceModels.discovery/2` no
  # tiene entrada suya, así que en la práctica no se le llama — se delega para
  # cumplir el behaviour sin inventar un camino nuevo.
  @impl true
  defdelegate list_service_models(provider, credential, endpoint), to: OpenAIAdapter

  # STT — chat with input_audio: the audio (base64 data URL or public URL)
  # becomes a content block on /chat/completions, and the transcription comes
  # back as the assistant message.
  @impl true
  def service_post(provider, credential, :stt, payload, opts) do
    chat_payload = stt_chat_payload(payload)

    with {:ok, body, latency, headers} <-
           OpenAIAdapter.chat_completion(provider, credential, chat_payload, opts) do
      {:ok, translate_stt_response(body), latency, headers}
    end
  end

  # TTS — native sync generation; answers output.audio.url (valid 24h).
  @impl true
  def service_post(provider, credential, :tts, payload, opts) do
    with {:ok, body, latency, headers} <-
           OpenAIAdapter.post_json_with_headers(
             provider,
             credential,
             native_url(provider, @tts_path),
             tts_native_payload(payload),
             [],
             opts
           ) do
      {:ok, translate_tts_response(body), latency, headers}
    end
  end

  # Everything else (chat-routed media like image):
  # OpenAI-compatible defaults, delegated.
  @impl true
  def service_post(provider, credential, service, payload, opts) do
    OpenAIAdapter.service_post(provider, credential, service, payload, opts)
  end

  ## STT translation ###########################################################

  @doc """
  The chat body a transcription request maps to. Accepts the OpenAI field
  names (`input_audio.data`, `file` as data URL) and DashScope's URL form
  (`audio_url` / `url`). Public: unit-testable.
  """
  def stt_chat_payload(payload) do
    %{
      "model" => Map.get(payload, "model"),
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_audio", "input_audio" => %{"data" => audio_input(payload)}}
          ]
        }
      ]
    }
  end

  defp audio_input(payload) do
    cond do
      is_map(payload["input_audio"]) ->
        Map.get(payload["input_audio"], "data") || ""

      is_binary(payload["file"]) ->
        payload["file"]

      is_binary(payload["audio_url"]) ->
        payload["audio_url"]

      is_binary(payload["url"]) ->
        payload["url"]

      true ->
        ""
    end
  end

  @doc """
  Extracts the transcribed text into the shape OpenAI's
  `/audio/transcriptions` returns: `{"text": …}` plus the upstream usage.
  Public: unit-testable.
  """
  def translate_stt_response(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body)
      when is_binary(content) do
    %{"text" => content, "usage" => Map.get(body, "usage")}
  end

  def translate_stt_response(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body)
      when is_list(content) do
    text =
      content
      |> Enum.map_join(&(Map.get(&1, "text") || ""))
      |> String.trim()

    %{"text" => text, "usage" => Map.get(body, "usage")}
  end

  def translate_stt_response(body), do: body

  ## TTS translation ###########################################################

  @doc """
  The native body a speech request maps to: `input.text` + `input.voice`
  (DashScope's MultiModalConversation TTS surface). Public: unit-testable.
  """
  def tts_native_payload(payload) do
    voice =
      case Map.get(payload, "voice") do
        v when is_binary(v) and v != "" -> v
        _ -> "Cherry"
      end

    %{
      "model" => Map.get(payload, "model"),
      "input" => %{"text" => Map.get(payload, "input") || "", "voice" => voice}
    }
  end

  @doc """
  Extracts the generated audio out of the native response: the upstream
  answers with a URL (`output.audio.url`) valid 24h — returned as `{"url": …}`
  so the client can fetch it. Public: unit-testable.
  """
  def translate_tts_response(%{"output" => %{"audio" => audio}} = body) when is_map(audio) do
    %{
      "url" => Map.get(audio, "url"),
      "data" => Map.get(audio, "data"),
      "usage" => Map.get(body, "usage")
    }
  end

  def translate_tts_response(body), do: body

  ## Internals ##################################################################

  # The native services live under /api/v1 of the SAME HOST as base_url:
  # https://dashscope-intl.aliyuncs.com/compatible-mode/v1 →
  # https://dashscope-intl.aliyuncs.com/api/v1/...
  defp native_url(provider, path) do
    base = Map.get(provider, :base_url) || Map.get(provider, "base_url") || ""

    case URI.parse(base) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        port_fragment = if port in [80, 443, nil], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_fragment}#{path}"

      _ ->
        path
    end
  end
end
