defmodule Tokengate.Proxy.DashScopeAdapter do
  @moduledoc """
  DashScope (Alibaba Model Studio / Qwen Cloud) dialect adapter.

  DashScope exposes a SPLIT surface:

    * **compatible-mode/v1** — OpenAI-compatible chat, models, embeddings
      and image (`/images/generations`, qwen-image). Delegated to
      `OpenAIAdapter` untouched (default paths).
    * **compatible-api/v1** — rerank at `/reranks`; already OpenAI-shaped
      (`{object: "list", results: [...]}`), delegated too (path override
      lives in `Catalog.@customizations`).
    * **NATIVE services** this adapter translates:
        * **stt** (qwen3-asr-flash): OpenAI-compatible but rides
          `/chat/completions` with an `input_audio` content block; the
          transcribed text comes back as the assistant message.
        * **tts** (qwen3-tts / cosyvoice): native
          `/api/v1/services/aigc/multimodal-generation/generation`, sync,
          answers `output.audio.url`.
        * **video** (wan2.x): native async
          `/api/v1/services/aigc/video-generation/video-synthesis` with the
          `X-DashScope-Async: enable` header, then poll `GET /api/v1/tasks/{id}`
          until `SUCCEEDED` and return the final document with `video_url`.

  The native services live under the `/api/v1` segment of the same host as
  base_url, which is why the paths here are ABSOLUTE URLs derived from the
  provider's host.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Proxy.OpenAIAdapter

  @native_base_path "/api/v1"
  @tts_path @native_base_path <> "/services/aigc/multimodal-generation/generation"
  @video_path @native_base_path <> "/services/aigc/video-generation/video-synthesis"
  @tasks_path @native_base_path <> "/tasks"

  @poll_interval_ms 10_000
  @task_terminal ~w(SUCCEEDED FAILED CANCELED UNKNOWN)

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

  # Video — native async: submit with X-DashScope-Async, poll the task until
  # SUCCEEDED, return the final document with video_url lifted to the top.
  @impl true
  def service_post(provider, credential, :video, payload, opts) do
    with {:ok, submitted, latency, headers} <-
           OpenAIAdapter.post_json_with_headers(
             provider,
             credential,
             native_url(provider, @video_path),
             video_native_payload(payload),
             [{"x-dashscope-async", "enable"}],
             opts
           ),
         {:ok, task_id} <- fetch_task_id(submitted),
         {:ok, final} <- poll_task(provider, credential, task_id, opts) do
      {:ok, translate_video_response(final), latency, headers}
    end
  end

  # Everything else (chat-routed media like image, rerank at compatible-api):
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

  ## Video translation #########################################################

  @doc """
  The native body a video request maps to: `input.prompt` plus the knobs
  DashScope accepts (resolution, ratio, duration…). Public: unit-testable.
  """
  def video_native_payload(payload) do
    input =
      payload
      |> Map.take(["prompt", "audio_url", "negative_prompt", "first_frame_url", "last_frame_url"])
      |> Map.new(fn {k, v} -> {k, v} end)
      |> Map.put_new("prompt", "")

    parameters =
      payload
      |> Map.take([
        "resolution",
        "ratio",
        "duration",
        "size",
        "prompt_extend",
        "watermark",
        "seed"
      ])

    %{"model" => Map.get(payload, "model"), "input" => input, "parameters" => parameters}
  end

  @doc """
  Normalizes the final task document into the gateway's video envelope,
  lifting `output.video_url`/status to the top so clients read one shape
  across upstreams. Public: unit-testable.
  """
  def translate_video_response(%{"output" => output} = body) when is_map(output) do
    body
    |> Map.put("video_url", Map.get(output, "video_url"))
    |> Map.put("status", task_status_to_gateway(Map.get(output, "task_status")))
    |> Map.put("task_id", Map.get(output, "task_id"))
  end

  def translate_video_response(body), do: body

  defp task_status_to_gateway("SUCCEEDED"), do: "completed"
  defp task_status_to_gateway("FAILED"), do: "failed"
  defp task_status_to_gateway("CANCELED"), do: "cancelled"
  defp task_status_to_gateway(other), do: other

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

  # El failure_reason del behaviour es un vocabulario CERRADO de átomos (ver
  # ProviderAdapter.failure_reason): una tupla aquí rompe el `to_string(reason)`
  # del controller (Protocol.UndefinedError) y la request muere en un 500
  # interno en vez de surficiar el fallo upstream. El detalle específico del
  # task viaja en error_message.
  defp fetch_task_id(%{"output" => %{"task_id" => id}}) when is_binary(id), do: {:ok, id}
  defp fetch_task_id(_), do: {:error, :server_error, nil, "no task id in submission response"}

  defp poll_task(provider, credential, task_id, opts) do
    url = native_url(provider, @tasks_path) <> "/#{task_id}"
    deadline = System.monotonic_time(:millisecond) + poll_budget(opts)
    interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    do_poll(provider, credential, url, deadline, interval)
  end

  defp do_poll(provider, credential, url, deadline, interval) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout, nil, "video task did not reach a terminal status before the deadline"}
    else
      Process.sleep(interval)

      case OpenAIAdapter.get_json(provider, credential, url, receive_timeout: 30_000) do
        {:ok, %{"output" => %{"task_status" => status}} = doc}
        when status in @task_terminal ->
          if status == "SUCCEEDED",
            do: {:ok, doc},
            else: {:error, :server_error, nil, "video task ended with status #{status}"}

        {:ok, _doc} ->
          do_poll(provider, credential, url, deadline, interval)

        {:error, reason} ->
          {:error, reason, nil, nil}
      end
    end
  end

  defp poll_budget(opts), do: Keyword.get(opts, :receive_timeout, 180_000)
end
