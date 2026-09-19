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
end
