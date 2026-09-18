defmodule Tokengate.Proxy.OpenRouterAdapterTest do
  @moduledoc """
  Unit tests of the OpenRouter adapter's OWN translations: music→chat and
  chat→music. The HTTP transport, video polling and error classification are
  `OpenAIAdapter`'s (delegated) and are exercised upstream, not here.
  """
  use Tokengate.DataCase, async: true

  alias Tokengate.Proxy.OpenRouterAdapter

  describe "music_chat_payload/1" do
    test "maps prompt → user message with audio modality" do
      payload = %{"model" => "google/lyria-3-pro-preview", "prompt" => "a surf rock song"}

      assert OpenRouterAdapter.music_chat_payload(payload) == %{
               "model" => "google/lyria-3-pro-preview",
               "modalities" => ["text", "audio"],
               "audio" => %{"voice" => "alloy", "format" => "mp3"},
               "messages" => [%{"role" => "user", "content" => "a surf rock song"}]
             }
    end

    test "keeps the client's format and stream flag" do
      payload = %{
        "model" => "google/lyria-3-pro-preview",
        "prompt" => "x",
        "format" => "wav",
        "stream" => true
      }

      chat = OpenRouterAdapter.music_chat_payload(payload)

      assert get_in(chat, ["audio", "format"]) == "wav"
      assert chat["stream"] == true
    end

    test "a missing prompt degrades to an empty message, never nil" do
      chat = OpenRouterAdapter.music_chat_payload(%{"model" => "m"})
      assert [%{"content" => ""}] = chat["messages"]
    end
  end

  describe "translate_music_response/1" do
    test "extracts the audio payload into the music envelope" do
      chat_body = %{
        "model" => "google/lyria-3-pro-preview",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "audio" => %{"data" => "QUJD", "format" => "mp3", "transcript" => "t"}
            }
          }
        ],
        "usage" => %{"total_tokens" => 12}
      }

      assert OpenRouterAdapter.translate_music_response(chat_body) == %{
               "object" => "music.generation",
               "data" => [%{"audio" => "QUJD", "format" => "mp3", "transcript" => "t"}],
               "model" => "google/lyria-3-pro-preview",
               "usage" => %{"total_tokens" => 12}
             }
    end

    test "an unexpected shape passes through untouched" do
      body = %{"error" => %{"message" => "boom"}}
      assert OpenRouterAdapter.translate_music_response(body) == body
    end
  end
end
