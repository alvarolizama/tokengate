defmodule Tokengate.Proxy.TokenPlanAdapterTest do
  @moduledoc """
  Las traducciones del dialecto `token_plan` (Alibaba Model Studio Token Plan).

  El transporte HTTP se ejercita contra el upstream real, no aquí: estos tests
  fijan los CUERPOS —el nativo que sale y el público que vuelve—, que es donde
  vive el dialecto. Los ejemplos salen de la doc del plan y de respuestas
  reales capturadas con una key `sk-sp-`.
  """
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.{MultipartFile, ProviderAdapter, TokenPlanAdapter}

  doctest Tokengate.Proxy.TokenPlanAdapter

  describe "image_payload/1" do
    test "maps the OpenAI form to the native multimodal body" do
      payload = %{
        "model" => "qwen-image-3.0-pro",
        "prompt" => "un faro al atardecer",
        "n" => 2,
        "size" => "1024x768"
      }

      assert TokenPlanAdapter.image_payload(payload) == %{
               "model" => "qwen-image-3.0-pro",
               "input" => %{
                 "messages" => [
                   %{"role" => "user", "content" => [%{"text" => "un faro al atardecer"}]}
                 ]
               },
               "parameters" => %{"size" => "1024*768", "n" => 2}
             }
    end

    test "keeps an already-native body untouched" do
      native = %{
        "model" => "wan2.7-image",
        "input" => %{"messages" => [%{"role" => "user", "content" => [%{"text" => "x"}]}]},
        "parameters" => %{"size" => "512*512"}
      }

      assert TokenPlanAdapter.image_payload(native) == native
    end

    test "omits parameters it cannot know instead of inventing them" do
      payload = TokenPlanAdapter.image_payload(%{"model" => "m", "prompt" => "x"})

      assert payload["parameters"] == %{}
    end
  end

  describe "image_response/1" do
    test "extracts the URLs into the OpenAI images shape" do
      body = %{
        "output" => %{
          "choices" => [
            %{
              "message" => %{
                "content" => [%{"type" => "image", "image" => "https://oss/1.png"}],
                "role" => "assistant"
              },
              "finish_reason" => "stop"
            }
          ]
        },
        "usage" => %{"output_image_count" => 1, "output_width" => 1024}
      }

      assert TokenPlanAdapter.image_response(body) == %{
               "data" => [%{"url" => "https://oss/1.png"}],
               "usage" => %{"output_image_count" => 1, "output_width" => 1024}
             }
    end

    test "a response with no image is an empty data list, not a crash" do
      assert TokenPlanAdapter.image_response(%{"output" => %{"choices" => []}}) == %{
               "data" => []
             }

      assert TokenPlanAdapter.image_response(%{}) == %{"data" => []}
    end
  end

  describe "tts_payload/1" do
    test "maps the OpenAI form onto SpeechSynthesizer's input" do
      payload = %{
        "model" => "qwen-audio-3.0-tts-plus",
        "input" => "hola mundo",
        "voice" => "Cherry",
        "response_format" => "wav",
        "speed" => 1.2
      }

      assert TokenPlanAdapter.tts_payload(payload) == %{
               "model" => "qwen-audio-3.0-tts-plus",
               "input" => %{"text" => "hola mundo", "voice" => "Cherry", "format" => "wav"}
             }
    end

    test "defaults to the plan's documented voice and mp3" do
      payload = TokenPlanAdapter.tts_payload(%{"model" => "m", "input" => "hola"})

      assert payload["input"] == %{
               "text" => "hola",
               "voice" => "longanhuan_v3.6",
               "format" => "mp3"
             }
    end

    test "keeps an already-native input map" do
      native = %{
        "model" => "m",
        "input" => %{"text" => "x", "voice" => "v", "sample_rate" => 22050}
      }

      assert TokenPlanAdapter.tts_payload(native) == native
    end
  end

  describe "tts_response/1" do
    test "returns the audio URL plus usage" do
      body = %{
        "output" => %{"audio" => %{"url" => "https://oss/a.mp3", "data" => ""}},
        "usage" => %{"characters" => 44, "total_tokens" => 49}
      }

      assert TokenPlanAdapter.tts_response(body) == %{
               "url" => "https://oss/a.mp3",
               "data" => "",
               "usage" => %{"characters" => 44, "total_tokens" => 49}
             }
    end

    test "no audio is a nil url, never an invented one" do
      assert TokenPlanAdapter.tts_response(%{"output" => %{}}) == %{
               "url" => nil,
               "data" => nil
             }
    end
  end

  describe "stt_payload/2" do
    test "accepts a URL" do
      assert {:ok, native} =
               TokenPlanAdapter.stt_payload(
                 %{"model" => "qwen-audio-3.0-asr-flash", "audio_url" => "https://a/1.mp3"},
                 []
               )

      assert get_in(native, ["input", "messages", Access.at(0), "content", Access.at(0)]) == %{
               "type" => "input_audio",
               "input_audio" => %{"data" => "https://a/1.mp3"}
             }

      assert native["parameters"] == %{"format" => "mp3"}
    end

    test "accepts a data URI and reads the format out of it" do
      assert {:ok, native} =
               TokenPlanAdapter.stt_payload(
                 %{
                   "model" => "m",
                   "input_audio" => %{"data" => "data:audio/wav;base64,QUJD"}
                 },
                 []
               )

      assert native["parameters"] == %{"format" => "wav"}
    end

    test "an explicit format wins over the deduction" do
      assert {:ok, native} =
               TokenPlanAdapter.stt_payload(
                 %{"model" => "m", "file" => "data:audio/mpeg;base64,QUJD", "format" => "wav"},
                 []
               )

      assert native["parameters"] == %{"format" => "wav"}
    end

    test "an unknown format falls back to mp3 instead of reaching the upstream" do
      assert {:ok, native} =
               TokenPlanAdapter.stt_payload(
                 %{"model" => "m", "file" => "data:audio/mpeg;base64,QUJD", "format" => "midi"},
                 []
               )

      assert native["parameters"] == %{"format" => "mp3"}
    end

    # El caso REAL del gateway: el cliente manda multipart, el proxy captura el
    # cuerpo crudo y el upstream quiere el audio como data URI.
    test "builds a data URI from the captured multipart bytes" do
      {raw_body, content_type} = multipart_audio("nota.mp3", "audio/mpeg", "ID3-audio-bytes")

      assert {:ok, native} =
               TokenPlanAdapter.stt_payload(
                 %{
                   "model" => "qwen-audio-3.0-asr-flash",
                   "file" => %Tokengate.Proxy.MediaFile{
                     filename: "nota.mp3",
                     content_type: "audio/mpeg"
                   }
                 },
                 raw_body: raw_body,
                 content_type: content_type
               )

      assert get_in(native, [
               "input",
               "messages",
               Access.at(0),
               "content",
               Access.at(0),
               "input_audio",
               "data"
             ]) ==
               "data:audio/mpeg;base64,#{Base.encode64("ID3-audio-bytes")}"

      assert native["parameters"] == %{"format" => "mp3"}
    end

    test "a request with no audio is a client error, not an upstream call" do
      assert {:error, message} = TokenPlanAdapter.stt_payload(%{"model" => "m"}, [])
      assert message =~ "carries no audio"
    end
  end

  describe "stt_response/1" do
    test "returns the transcribed text and the billable duration" do
      body = %{
        "output" => %{"text" => "Hola, esto es una prueba.", "sentence" => %{"sentence_id" => 1}},
        "usage" => %{"duration" => 3},
        "request_id" => "abc"
      }

      assert TokenPlanAdapter.stt_response(body) == %{
               "text" => "Hola, esto es una prueba.",
               "usage" => %{"duration" => 3}
             }
    end

    test "a silent upstream yields empty text" do
      assert TokenPlanAdapter.stt_response(%{"output" => %{}}) == %{"text" => ""}
    end
  end

  describe "dispatch/1" do
    test "the token_plan dialect resolves to this adapter" do
      assert ProviderAdapter.dispatch(%{dialect: "token_plan"}) == TokenPlanAdapter
      assert ProviderAdapter.dispatch(%{"dialect" => "token_plan"}) == TokenPlanAdapter

      refute ProviderAdapter.dispatch(%{dialect: "token_plan"}) ==
               Tokengate.Proxy.DashScopeAdapter
    end
  end

  describe "MultipartFile.extract/2" do
    test "returns the file part's bytes, filename and content-type" do
      {raw_body, content_type} = multipart_audio("voz.wav", "audio/wav", "RIFF....WAVE")

      assert {:ok, part} = MultipartFile.extract(raw_body, content_type)
      assert part.bytes == "RIFF....WAVE"
      assert part.filename == "voz.wav"
      assert part.content_type == "audio/wav"
    end

    test "a form field before the file is skipped, not returned" do
      boundary = "----tpboundary"

      raw =
        Enum.join(
          [
            "--#{boundary}",
            "Content-Disposition: form-data; name=\"model\"",
            "",
            "whisper",
            "--#{boundary}",
            "Content-Disposition: form-data; name=\"file\"; filename=\"a.ogg\"",
            "Content-Type: audio/ogg",
            "",
            "OggS-bytes",
            "--#{boundary}--",
            ""
          ],
          "\r\n"
        )

      assert {:ok, part} = MultipartFile.extract(raw, "multipart/form-data; boundary=#{boundary}")
      assert part.bytes == "OggS-bytes"
      assert part.content_type == "audio/ogg"
    end

    test "a non-multipart body is not a file" do
      assert MultipartFile.extract(~s({"a": 1}), "application/json") == :error
      assert MultipartFile.extract(nil, nil) == :error
      assert MultipartFile.extract("x", "multipart/form-data") == :error
    end
  end

  # Un cuerpo multipart mínimo, con la forma que manda un cliente OpenAI: un
  # campo de formulario (`model`) y la parte del archivo.
  defp multipart_audio(filename, content_type, bytes) do
    boundary = "----tokenplan#{System.unique_integer([:positive])}"

    raw =
      Enum.join(
        [
          "--#{boundary}",
          "Content-Disposition: form-data; name=\"model\"",
          "",
          "qwen-audio-3.0-asr-flash",
          "--#{boundary}",
          "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"",
          "Content-Type: #{content_type}",
          "",
          bytes,
          "--#{boundary}--",
          ""
        ],
        "\r\n"
      )

    {raw, "multipart/form-data; boundary=#{boundary}"}
  end
end
