defmodule Tokengate.Proxy.OpenRouterAdapter do
  @moduledoc """
  OpenRouter dialect adapter.

  OpenRouter speaks the OpenAI-compatible surface for chat, embeddings and
  most path-routed services, with these deviations this adapter owns:

    * embedding models are listed at `{base_url}/embeddings/models` instead
      of `{base_url}/models`;
    * **video** (`/videos`) is ASYNC: the POST answers `{id, status,
      polling_url}` (202) and the finished asset arrives only after polling.
      The gateway's contract is synchronous, so this adapter polls internally
      until a terminal status and returns the final job document;
    * **music** has NO dedicated endpoint: OpenRouter generates audio via
      `/chat/completions` with `modalities: ["text","audio"]`. This adapter
      translates a music request into that chat shape and back.

  Everything else is delegated to `OpenAIAdapter` untouched.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Proxy.OpenAIAdapter

  # Video jobs poll every 10s at most, until one of these statuses or the
  # caller's receive timeout. OpenRouter's own docs suggest ~30s intervals;
  # 10s keeps the gateway's latency floor low without hammering the API.
  @video_poll_interval_ms 10_000
  @video_terminal ~w(completed failed cancelled expired)

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

  @impl true
  def service_post(provider, credential, :video, payload, opts) do
    with {:ok, job, latency, headers} <-
           OpenAIAdapter.service_post(
             provider,
             credential,
             :video,
             payload,
             opts
           ),
         {:ok, final} <- poll_video(provider, credential, job, opts) do
      {:ok, final, latency, headers}
    end
  end

  # Music rides the chat endpoint with audio modality: the client's `prompt`
  # becomes the user message and the audio chunks come back in the message.
  # The final audio (base64 in `choices[0].message.audio.data`) is re-shaped
  # into a music-style response with the same envelope as any other service.
  @impl true
  def service_post(provider, credential, :music, payload, opts) do
    chat_payload = music_chat_payload(payload)

    with {:ok, body, latency, headers} <-
           OpenAIAdapter.chat_completion(provider, credential, chat_payload, opts) do
      {:ok, translate_music_response(body), latency, headers}
    end
  end

  def service_post(provider, credential, service, payload, opts) do
    OpenAIAdapter.service_post(provider, credential, service, payload, opts)
  end

  @doc """
  The chat body a music request maps to: audio modality, the prompt as the
  user message. Public so the translation is unit-testable.
  """
  def music_chat_payload(payload) do
    base = %{
      "model" => Map.get(payload, "model"),
      "modalities" => ["text", "audio"],
      "audio" => %{"voice" => "alloy", "format" => Map.get(payload, "format") || "mp3"},
      "messages" => [
        %{"role" => "user", "content" => Map.get(payload, "prompt") || ""}
      ]
    }

    case Map.get(payload, "stream") do
      nil -> base
      stream -> Map.put(base, "stream", stream)
    end
  end

  @doc """
  Extracts the generated audio out of a chat completion and wraps it in the
  envelope the gateway's music contract returns. Public: unit-testable.
  """
  def translate_music_response(%{"choices" => [%{"message" => message} | _]} = body) do
    audio = Map.get(message, "audio") || %{}

    %{
      "object" => "music.generation",
      "data" => [
        %{
          "audio" => Map.get(audio, "data"),
          "format" => Map.get(audio, "format") || "mp3",
          "transcript" => Map.get(audio, "transcript")
        }
      ],
      "model" => Map.get(body, "model"),
      "usage" => Map.get(body, "usage")
    }
  end

  def translate_music_response(body), do: body

  ## Video polling #############################################################

  # Polls the async video job until a terminal status. The 202 document
  # already carries `polling_url` (OpenRouter returns it absolute); when it
  # is missing the canonical `/videos/{id}` is derived from the job id.
  defp poll_video(provider, credential, job, opts) do
    url = polling_url(provider, job)
    deadline = System.monotonic_time(:millisecond) + poll_budget(opts)

    do_poll(provider, credential, url, deadline, job)
  end

  defp do_poll(provider, credential, url, deadline, _job) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :video_poll_timeout, nil, nil}
    else
      Process.sleep(@video_poll_interval_ms)

      case OpenAIAdapter.get_json(provider, credential, url, receive_timeout: 30_000) do
        {:ok, %{"status" => status} = doc} when status in @video_terminal ->
          if status == "completed", do: {:ok, doc}, else: {:error, {:video, status}, nil, nil}

        {:ok, doc} ->
          do_poll(provider, credential, url, deadline, doc)

        {:error, reason} ->
          {:error, reason, nil, nil}
      end
    end
  end

  # The poll budget inherits the caller's receive timeout (the gateway's
  # 180s default covers most generations) but never exceeds it: a video that
  # outlives the request just times out like any other slow upstream.
  defp poll_budget(opts) do
    Keyword.get(opts, :receive_timeout, 180_000)
  end

  defp polling_url(provider, job) do
    case job do
      %{"polling_url" => url} when is_binary(url) and url != "" ->
        # polling_url can be absolute (https://openrouter.ai/api/v1/…) or
        # path-relative (/api/v1/videos/…): build_url handles both.
        url

      %{"id" => id} when is_binary(id) ->
        Tokengate.Providers.ProviderPaths.resolve(provider, :video) || "/videos/#{id}"

      _ ->
        "/videos"
    end
  end
end
