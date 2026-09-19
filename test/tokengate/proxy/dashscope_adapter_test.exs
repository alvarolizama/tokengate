defmodule Tokengate.Proxy.DashScopeAdapterTest do
  @moduledoc """
  Unit tests of the DashScope adapter's translations: stt→chat, tts→native
  and video→native async. The HTTP transport and the task polling loop are
  exercised against the real upstream, not here.
  """
  use Tokengate.DataCase, async: true

  alias Tokengate.Proxy.DashScopeAdapter

  describe "stt_chat_payload/1" do
    test "maps input_audio.data (OpenAI JSON form) onto the chat body" do
      payload = %{
        "model" => "qwen3-asr-flash",
        "input_audio" => %{"data" => "data:audio/wav;base64,QUJD", "format" => "wav"}
      }

      assert DashScopeAdapter.stt_chat_payload(payload) == %{
               "model" => "qwen3-asr-flash",
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "input_audio",
                       "input_audio" => %{"data" => "data:audio/wav;base64,QUJD"}
                     }
                   ]
                 }
               ]
             }
    end

    test "accepts file (data URL), audio_url and url forms too" do
      base = %{"model" => "m"}

      assert get_in(DashScopeAdapter.stt_chat_payload(Map.put(base, "file", "data:x")), [
               "messages",
               Access.at(0),
               "content",
               Access.at(0),
               "input_audio",
               "data"
             ]) == "data:x"

      assert get_in(DashScopeAdapter.stt_chat_payload(Map.put(base, "audio_url", "https://a")), [
               "messages",
               Access.at(0),
               "content",
               Access.at(0),
               "input_audio",
               "data"
             ]) == "https://a"

      assert get_in(DashScopeAdapter.stt_chat_payload(Map.put(base, "url", "https://b")), [
               "messages",
               Access.at(0),
               "content",
               Access.at(0),
               "input_audio",
               "data"
             ]) == "https://b"
    end
  end

  describe "translate_stt_response/1" do
    test "extracts the assistant text as the transcription" do
      chat = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "hola mundo"}}],
        "usage" => %{"total_tokens" => 9}
      }

      assert DashScopeAdapter.translate_stt_response(chat) == %{
               "text" => "hola mundo",
               "usage" => %{"total_tokens" => 9}
             }
    end

    test "unexpected shapes pass through untouched" do
      body = %{"error" => %{"message" => "boom"}}
      assert DashScopeAdapter.translate_stt_response(body) == body
    end
  end

  describe "tts_native_payload/1" do
    test "maps input/voice onto the native input object" do
      payload = %{"model" => "qwen3-tts-flash", "input" => "Hola", "voice" => "Chelsie"}

      assert DashScopeAdapter.tts_native_payload(payload) == %{
               "model" => "qwen3-tts-flash",
               "input" => %{"text" => "Hola", "voice" => "Chelsie"}
             }
    end

    test "a missing voice defaults to Cherry" do
      payload = %{"model" => "qwen3-tts-flash", "input" => "Hola"}

      assert get_in(DashScopeAdapter.tts_native_payload(payload), ["input", "voice"]) == "Cherry"
    end
  end

  describe "translate_tts_response/1" do
    test "lifts output.audio into the url/data envelope" do
      native = %{
        "output" => %{
          "audio" => %{"url" => "https://oss/x.wav", "data" => ""},
          "finish_reason" => "stop"
        },
        "usage" => %{"characters" => 12}
      }

      assert DashScopeAdapter.translate_tts_response(native) == %{
               "url" => "https://oss/x.wav",
               "data" => "",
               "usage" => %{"characters" => 12}
             }
    end
  end

  describe "video_native_payload/1" do
    test "maps prompt + knobs into input/parameters" do
      payload = %{
        "model" => "wan2.7-t2v",
        "prompt" => "a cat",
        "resolution" => "720P",
        "ratio" => "16:9",
        "duration" => 5,
        "ignored_field" => true
      }

      native = DashScopeAdapter.video_native_payload(payload)

      assert native["model"] == "wan2.7-t2v"
      assert native["input"] == %{"prompt" => "a cat"}
      assert native["parameters"] == %{"resolution" => "720P", "ratio" => "16:9", "duration" => 5}
    end
  end

  describe "translate_video_response/1" do
    test "lifts video_url/status/task_id to the top level" do
      task = %{
        "request_id" => "r",
        "output" => %{
          "task_id" => "t-1",
          "task_status" => "SUCCEEDED",
          "video_url" => "https://oss/v.mp4"
        },
        "usage" => %{"video_count" => 1}
      }

      translated = DashScopeAdapter.translate_video_response(task)

      assert translated["video_url"] == "https://oss/v.mp4"
      assert translated["status"] == "completed"
      assert translated["task_id"] == "t-1"
      # el doc original se conserva
      assert translated["usage"] == %{"video_count" => 1}
    end

    test "FAILED maps to failed" do
      task = %{"output" => %{"task_status" => "FAILED", "code" => "InvalidParameter"}}

      assert DashScopeAdapter.translate_video_response(task)["status"] == "failed"
    end
  end

  describe "service_post(:video) polling" do
    # Regresión del crash `Protocol.UndefinedError`: el polling de un task
    # FAILED devolvía `{:error, {:task, "FAILED"}, nil, nil}` — una razón
    # FUERA del vocabulario de failure_reason — y el controller crasheaba en
    # `to_string(reason)` al serializar el error. El contrato ahora es átomo
    # + detalle en error_message.
    @describetag :capture_log

    @port 31_997

    defmodule VideoPlug do
      @moduledoc false
      import Plug.Conn

      def init(opts), do: opts

      def call(conn, _opts) do
        case conn.request_path do
          "/api/v1/services/aigc/video-generation/video-synthesis" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{"output" => %{"task_id" => "t-1", "task_status" => "PENDING"}})
            )

          "/api/v1/tasks/t-1" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{
                "output" => %{
                  "task_id" => "t-1",
                  "task_status" => "FAILED",
                  "code" => "InternalError"
                }
              })
            )

          _ ->
            send_resp(conn, 404, "not found")
        end
      end
    end

    setup do
      start_supervised!({Bandit, plug: VideoPlug, scheme: :http, ip: :loopback, port: @port})
      :ok
    end

    test "a FAILED task surfaces as a 4-tuple with an atom reason, not a tuple" do
      provider = %{base_url: "http://localhost:#{@port}/compatible-mode/v1"}
      credential = %{api_key_encrypted: "sk-test"}

      result =
        DashScopeAdapter.service_post(provider, credential, :video, %{"prompt" => "un gato"},
          poll_interval_ms: 1,
          receive_timeout: 5_000
        )

      assert {:error, :server_error, nil, message} = result
      assert message =~ "FAILED"
      # La razón debe ser serializable — esto es lo que crasheaba antes.
      assert is_atom(:server_error)
    end
  end
end
