defmodule Tokengate.Proxy.TokenPlanAdapter do
  @moduledoc """
  Alibaba Cloud Model Studio **Token Plan** (`sk-sp-` keys).

  El plan expone dos superficies en el mismo host, y **ninguna de las dos es la
  del dialecto `dashscope`**:

    * **compatible-mode/v1** — chat, models y health: OpenAI-compatible,
      delegado a `OpenAIAdapter` sin tocar.
    * **api/v1 nativo** — cada servicio de media en SU endpoint, traducido
      aquí:
        * **image** → `POST /api/v1/services/aigc/multimodal-generation/generation`
          con `input.messages[0].content[0].text` y `parameters.size` en
          `W*H`; responde `output.choices[0].message.content[0].image` (URL).
        * **tts** → `POST /api/v1/services/audio/tts/SpeechSynthesizer`
          (`input.text/voice/format/sample_rate`); responde `output.audio.url`.
        * **stt** → `POST /api/v1/services/aigc/multimodal-generation/generation`
          con `input.messages[0].content[0].input_audio.data` (URL o data URI)
          y `parameters.format` **obligatorio**; responde `output.text` y
          `usage.duration` (segundos).

  Verificado contra `token-plan.ap-southeast-1.maas.aliyuncs.com` el
  2026-11-16 con una key real: `compatible-mode/v1/images/generations` responde
  **404**, el chat con `input_audio` responde **400** y el TTS por
  `multimodal-generation` responde **400** (`url error`). De ahí que este
  dialecto tenga caminos y cuerpos propios en vez de reusar los de `dashscope`,
  que apunta a la superficie de DashScope a secas.

  El plan NO sirve embeddings (su `/models` no trae ninguno), así que
  `embeddings/4` se delega por contrato pero no hay tipo `embedding` que
  declarar en el catálogo.

  Los cuerpos que salen de aquí son los de la API pública del gateway, no los
  nativos: una respuesta de imagen se traduce al shape de OpenAI
  (`data[].url`), para que el cliente apunte su SDK de siempre y no tenga que
  aprender el envelope de DashScope. El TTS conserva el contrato del dialecto
  `dashscope` (`{"url": …}`, el cliente descarga el audio), y el STT devuelve
  `{"text": …}` como `/audio/transcriptions`.

  Las rutas de los tres servicios son FIJAS: derivan del host de `base_url` y
  **no** pasan por `ProviderPaths`, así que un override de la modal Capacidades
  no las mueve (misma regla que el dialecto `dashscope`). Si el plan cambia de
  endpoints, se cambia aquí y viaja con el release.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter

  alias Tokengate.Proxy.{MultipartFile, OpenAIAdapter, ProviderAdapter}

  # Los servicios nativos viven bajo `/api/v1` del MISMO host que `base_url`
  # (…/compatible-mode/v1 → …/api/v1/...).
  @native_base_path "/api/v1"
  @generation_path @native_base_path <> "/services/aigc/multimodal-generation/generation"
  @tts_path @native_base_path <> "/services/audio/tts/SpeechSynthesizer"

  # Defaults de la doc del plan: la voz de los ejemplos y mp3 como formato.
  @default_voice "longanhuan_v3.6"
  @default_audio_format "mp3"

  # content-type / extensión → `parameters.format` (el nombre que DashScope
  # documenta para el audio de entrada).
  @format_by_mime %{
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/wav" => "wav",
    "audio/x-wav" => "wav",
    "audio/wave" => "wav",
    "audio/ogg" => "ogg",
    "audio/opus" => "opus",
    "audio/flac" => "flac",
    "audio/x-flac" => "flac",
    "audio/mp4" => "m4a",
    "audio/m4a" => "m4a",
    "audio/x-m4a" => "m4a",
    "audio/aac" => "aac",
    "audio/webm" => "webm",
    "audio/amr" => "amr"
  }

  @formats ~w(mp3 wav ogg opus flac m4a aac webm amr)

  ## Chat: OpenAI-compatible ###################################################

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

  # El plan no publica catálogo por servicio (`ServiceModels.discovery/2` no
  # tiene entrada suya): se delega para cumplir el behaviour sin inventar un
  # camino nuevo.
  @impl true
  defdelegate list_service_models(provider, credential, endpoint), to: OpenAIAdapter

  ## Servicios de media ########################################################

  # Imagen: el plan NO tiene `/images/generations` en compatible-mode (404
  # verificado), así que va al nativo multimodal-generation y la respuesta se
  # traduce al shape de OpenAI.
  @impl true
  def service_post(provider, credential, :image, payload, opts) do
    with {:ok, body, latency, headers} <-
           post_native(provider, credential, @generation_path, image_payload(payload), opts) do
      {:ok, image_response(body), latency, headers}
    end
  end

  # TTS: SpeechSynthesizer nativo (el multimodal-generation que usa el dialecto
  # `dashscope` responde 400 `url error` con qwen-audio-3.0-tts-plus).
  @impl true
  def service_post(provider, credential, :tts, payload, opts) do
    with {:ok, body, latency, headers} <-
           post_native(provider, credential, @tts_path, tts_payload(payload), opts) do
      {:ok, tts_response(body), latency, headers}
    end
  end

  # STT: el plan solo acepta el audio NATIVO (chat con `input_audio` da 400).
  # El cuerpo del cliente es multipart y sus bytes viven en el cuerpo crudo
  # capturado: `MultipartFile` los saca y aquí se vuelven un data URI.
  @impl true
  def service_post(provider, credential, :stt, payload, opts) do
    case stt_payload(payload, opts) do
      {:ok, native} ->
        with {:ok, body, latency, headers} <-
               post_native(provider, credential, @generation_path, native, opts) do
          {:ok, stt_response(body), latency, headers}
        end

      {:error, message} ->
        # Sin audio no hay nada que mandar: es culpa del cliente, no del
        # upstream, y no debe gastar un intento del fallback.
        {:error, :bad_request, 400, message}
    end
  end

  # Cualquier otro servicio (chat-routed): defaults OpenAI-compatible.
  @impl true
  def service_post(provider, credential, service, payload, opts) do
    OpenAIAdapter.service_post(provider, credential, service, payload, opts)
  end

  ## Imagen ####################################################################

  @doc """
  El cuerpo nativo de una generación de imagen.

  Acepta la forma OpenAI (`prompt`, `n`, `size` en `WxH`) y la nativa ya hecha
  (`input.messages`), que se respeta tal cual. `size` se normaliza a `W*H`, que
  es como lo documenta el plan.

      iex> Tokengate.Proxy.TokenPlanAdapter.image_payload(%{"model" => "qwen-image-3.0-pro", "prompt" => "un gato", "size" => "1024x1024"})
      %{
        "model" => "qwen-image-3.0-pro",
        "input" => %{"messages" => [%{"role" => "user", "content" => [%{"text" => "un gato"}]}]},
        "parameters" => %{"size" => "1024*1024"}
      }

      iex> Tokengate.Proxy.TokenPlanAdapter.image_payload(%{"model" => "m", "input" => %{"messages" => []}, "parameters" => %{"size" => "512*512"}})
      %{"model" => "m", "input" => %{"messages" => []}, "parameters" => %{"size" => "512*512"}}
  """
  @spec image_payload(map()) :: map()
  def image_payload(%{"input" => %{} = input} = payload) do
    %{
      "model" => payload["model"],
      "input" => input,
      "parameters" => Map.get(payload, "parameters", %{})
    }
  end

  def image_payload(payload) when is_map(payload) do
    %{
      "model" => payload["model"],
      "input" => %{
        "messages" => [
          %{"role" => "user", "content" => [%{"text" => to_string(payload["prompt"] || "")}]}
        ]
      },
      "parameters" => image_parameters(payload)
    }
  end

  @doc """
  Traduce la respuesta nativa al shape de OpenAI images: `data[].url`.

      iex> Tokengate.Proxy.TokenPlanAdapter.image_response(%{"output" => %{"choices" => [%{"message" => %{"content" => [%{"image" => "https://x/1.png"}]}}]}, "usage" => %{"output_image_count" => 1}})
      %{"data" => [%{"url" => "https://x/1.png"}], "usage" => %{"output_image_count" => 1}}

      iex> Tokengate.Proxy.TokenPlanAdapter.image_response(%{"output" => %{"choices" => []}})
      %{"data" => []}
  """
  @spec image_response(map()) :: map()
  def image_response(body) when is_map(body) do
    data =
      body
      |> image_urls()
      |> Enum.map(&%{"url" => &1})

    case body["usage"] do
      %{} = usage -> %{"data" => data, "usage" => usage}
      _ -> %{"data" => data}
    end
  end

  ## TTS #######################################################################

  @doc """
  El cuerpo nativo de una síntesis de voz (`SpeechSynthesizer`).

  La forma OpenAI (`input` string, `voice`, `response_format`) se traduce a
  `input.text/voice/format`; un `input` que YA es mapa viaja tal cual. `speed`
  no existe en este wire y se descarta.

      iex> Tokengate.Proxy.TokenPlanAdapter.tts_payload(%{"model" => "qwen-audio-3.0-tts-plus", "input" => "hola", "voice" => "Cherry", "response_format" => "wav"})
      %{"model" => "qwen-audio-3.0-tts-plus", "input" => %{"text" => "hola", "voice" => "Cherry", "format" => "wav"}}

      iex> Tokengate.Proxy.TokenPlanAdapter.tts_payload(%{"model" => "m", "input" => "hola"})
      %{"model" => "m", "input" => %{"text" => "hola", "voice" => "longanhuan_v3.6", "format" => "mp3"}}
  """
  @spec tts_payload(map()) :: map()
  def tts_payload(%{"input" => %{} = input} = payload) do
    %{"model" => payload["model"], "input" => input}
  end

  def tts_payload(payload) when is_map(payload) do
    %{
      "model" => payload["model"],
      "input" => %{
        "text" => to_string(payload["input"] || ""),
        "voice" => present(payload["voice"]) || @default_voice,
        "format" => audio_format(payload["response_format"] || payload["format"])
      }
    }
  end

  @doc """
  Traduce la respuesta nativa: la URL del audio (válida ~24 h) más el usage.

      iex> Tokengate.Proxy.TokenPlanAdapter.tts_response(%{"output" => %{"audio" => %{"url" => "https://a/1.mp3"}}, "usage" => %{"characters" => 44}})
      %{"url" => "https://a/1.mp3", "data" => nil, "usage" => %{"characters" => 44}}

      iex> Tokengate.Proxy.TokenPlanAdapter.tts_response(%{"output" => %{}})
      %{"url" => nil, "data" => nil}
  """
  @spec tts_response(map()) :: map()
  def tts_response(body) when is_map(body) do
    audio = get_in(body, ["output", "audio"]) || %{}
    result = %{"url" => audio["url"], "data" => audio["data"]}

    case body["usage"] do
      %{} = usage -> Map.put(result, "usage", usage)
      _ -> result
    end
  end

  ## STT #######################################################################

  @doc """
  El cuerpo nativo de una transcripción, o `{:error, message}` cuando la
  request no trae audio.

  Fuentes de audio, en orden: `input_audio.data` (data URI o URL), `file` como
  data URI/URL, `audio_url`/`url`, y —el caso real del gateway— los BYTES del
  multipart capturado en `opts[:raw_body]`, que se vuelven un data URI con el
  content-type de la parte.

      iex> Tokengate.Proxy.TokenPlanAdapter.stt_payload(%{"model" => "qwen-audio-3.0-asr-flash", "input_audio" => %{"data" => "https://a/1.mp3"}}, [])
      {:ok, %{"model" => "qwen-audio-3.0-asr-flash", "input" => %{"messages" => [%{"role" => "user", "content" => [%{"type" => "input_audio", "input_audio" => %{"data" => "https://a/1.mp3"}}]}]}, "parameters" => %{"format" => "mp3"}}}

      iex> Tokengate.Proxy.TokenPlanAdapter.stt_payload(%{"model" => "m"}, [])
      {:error, "the transcription request carries no audio (file part, input_audio, audio_url or url)"}
  """
  @spec stt_payload(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def stt_payload(payload, opts \\ []) when is_map(payload) do
    case audio_source(payload, opts) do
      {:ok, data, format} ->
        {:ok,
         %{
           "model" => payload["model"],
           "input" => %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_audio", "input_audio" => %{"data" => data}}
                 ]
               }
             ]
           },
           "parameters" => %{"format" => format}
         }}

      :error ->
        {:error,
         "the transcription request carries no audio (file part, input_audio, audio_url or url)"}
    end
  end

  @doc """
  Traduce la respuesta nativa: el texto reconocido y la duración facturable.

      iex> Tokengate.Proxy.TokenPlanAdapter.stt_response(%{"output" => %{"text" => "hola"}, "usage" => %{"duration" => 3}})
      %{"text" => "hola", "usage" => %{"duration" => 3}}

      iex> Tokengate.Proxy.TokenPlanAdapter.stt_response(%{"output" => %{}})
      %{"text" => ""}
  """
  @spec stt_response(map()) :: map()
  def stt_response(body) when is_map(body) do
    result = %{"text" => get_in(body, ["output", "text"]) || ""}

    case body["usage"] do
      %{} = usage -> Map.put(result, "usage", usage)
      _ -> result
    end
  end

  ## Internals #################################################################

  defp post_native(provider, credential, path, payload, opts) do
    OpenAIAdapter.post_json_with_headers(
      provider,
      credential,
      ProviderAdapter.origin_url(provider, path),
      payload,
      [],
      opts
    )
  end

  defp image_parameters(payload) do
    %{}
    |> put_present("size", dash_size(payload["size"]))
    |> put_present("n", int(payload["n"]))
  end

  # "1024x1024" (OpenAI) → "1024*1024" (DashScope). Lo que ya viene con `*`
  # se queda igual.
  defp dash_size(size) when is_binary(size) do
    case String.split(size, "x") do
      [w, h] when w != "" and h != "" -> "#{w}*#{h}"
      _ -> present(size)
    end
  end

  defp dash_size(_size), do: nil

  defp image_urls(body) do
    body
    |> get_in_choices()
    |> Enum.flat_map(fn item ->
      case item do
        %{"image" => url} when is_binary(url) and url != "" -> [url]
        _ -> []
      end
    end)
  end

  defp get_in_choices(body) do
    case get_in(body, ["output", "choices"]) do
      choices when is_list(choices) ->
        Enum.flat_map(choices, fn
          %{"message" => %{"content" => content}} when is_list(content) -> content
          _ -> []
        end)

      _ ->
        []
    end
  end

  # Audio de entrada: lo que traiga la request, o los bytes del multipart.
  defp audio_source(payload, opts) do
    cond do
      is_binary(data = get_in(payload, ["input_audio", "data"])) and data != "" ->
        {:ok, data, audio_format(format_hint(payload, data))}

      is_binary(file = payload["file"]) and file != "" ->
        {:ok, file, audio_format(format_hint(payload, file))}

      is_binary(url = payload["audio_url"]) and url != "" ->
        {:ok, url, audio_format(format_hint(payload, url))}

      is_binary(url = payload["url"]) and url != "" ->
        {:ok, url, audio_format(format_hint(payload, url))}

      true ->
        from_raw_body(payload, opts)
    end
  end

  defp from_raw_body(payload, opts) do
    raw_body = Keyword.get(opts, :raw_body)
    content_type = Keyword.get(opts, :content_type)

    case MultipartFile.extract(raw_body, content_type) do
      {:ok, %{} = part} ->
        mime = part.content_type || mime_from_filename(part.filename)
        data = "data:#{mime || "audio/mpeg"};base64,#{Base.encode64(part.bytes)}"
        {:ok, data, audio_format(format_hint(payload, part.filename || mime))}

      :error ->
        :error
    end
  end

  defp format_hint(payload, source) do
    payload["format"] || payload["response_format"] || format_from_source(source)
  end

  # `parameters.format` es OBLIGATORIO en este wire: se deduce del propio
  # valor cuando ya es un formato (`wav`), del data URI
  # (`data:audio/wav;base64,…`), del content-type (`audio/mpeg`) o de la
  # extensión del archivo. Sin señal, `audio_format/1` cae a mp3.
  defp format_from_source(source) when is_binary(source) do
    normalized = String.downcase(String.trim(source))

    cond do
      normalized in @formats -> normalized
      Map.has_key?(@format_by_mime, normalized) -> normalized
      String.starts_with?(normalized, "data:") -> mime_of_data_uri(normalized)
      true -> extension_of(source)
    end
  end

  defp format_from_source(_source), do: nil

  defp mime_of_data_uri(data_uri) do
    case String.split(data_uri, ["data:", ";"]) do
      [_empty, mime | _] -> mime
      _ -> nil
    end
  end

  defp extension_of(value) do
    case value |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() do
      "" -> nil
      "." <> ext -> ext
      _ -> nil
    end
  end

  defp audio_format(nil), do: @default_audio_format

  defp audio_format(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized in @formats ->
        normalized

      Map.has_key?(@format_by_mime, normalized) ->
        Map.fetch!(@format_by_mime, normalized)

      true ->
        @default_audio_format
    end
  end

  defp audio_format(_value), do: @default_audio_format

  defp mime_from_filename(nil), do: nil

  defp mime_from_filename(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    Enum.find_value(@format_by_mime, fn {mime, format} -> if format == ext, do: mime end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp int(_value), do: nil
end
