defmodule Tokengate.Proxy.AudioMultipartTest do
  @moduledoc """
  The canonical body for an STT upload: a valid multipart must travel untouched,
  and every other shape a client really sends must be rebuilt into one — or be
  rejected with a message the caller can act on.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.AudioMultipart

  doctest Tokengate.Proxy.AudioMultipart

  @boundary "client-boundary-123"
  @ogg <<"OggS", 0, 2, 0, 0, 0, 0, 0, 0>>
  @mp3 <<0xFF, 0xFB, 0x90, 0x64>>
  @wav <<"RIFF", 36::32, "WAVE", "fmt ">>

  defp multipart(parts) do
    body =
      parts
      |> Enum.map(fn part -> encode(@boundary, part) end)
      |> Enum.concat([["--", @boundary, "--\r\n"]])
      |> IO.iodata_to_binary()

    {body, "multipart/form-data; boundary=#{@boundary}"}
  end

  defp encode(boundary, {name, opts}) do
    filename = Keyword.get(opts, :filename)
    content_type = Keyword.get(opts, :content_type)
    value = Keyword.fetch!(opts, :value)

    disposition =
      case filename do
        nil -> ~s(content-disposition: form-data; name="#{name}")
        file -> ~s(content-disposition: form-data; name="#{name}"; filename="#{file}")
      end

    type = if content_type, do: ["content-type: ", content_type, "\r\n"], else: []

    ["--", boundary, "\r\n", disposition, "\r\n", type, "\r\n", value, "\r\n"]
  end

  defp rebuilt({:ok, body, content_type, :rebuilt}) do
    assert content_type =~ "multipart/form-data; boundary="
    body
  end

  defp contains?(body, needle), do: :binary.match(body, needle) != :nomatch

  defp base64(bytes), do: Base.encode64(bytes)

  describe "a canonical upload" do
    test "travels with the same bytes and the same content-type" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      assert {:ok, ^body, ^content_type, :unchanged} =
               AudioMultipart.canonicalize(body, content_type, %{"model" => "whisper"})
    end
  end

  describe "a file part without a filename" do
    test "gets one derived from the audio inside" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper"},
          {"language", value: "es"},
          {"file", content_type: "audio/ogg", value: @ogg}
        ])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))

      assert rebuilt =~ ~s(content-disposition: form-data; name="file"; filename="audio.ogg")
      assert rebuilt =~ ~s(content-disposition: form-data; name="model")
      assert rebuilt =~ ~s(content-disposition: form-data; name="language")
      assert contains?(rebuilt, @ogg)
      refute rebuilt =~ ~s(name="audio")
    end

    test "gets an mp3 name from the frame header" do
      {body, content_type} = multipart([{"file", value: @mp3}])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))
      assert rebuilt =~ ~s(filename="audio.mp3")
      assert contains?(rebuilt, @mp3)
    end

    test "is decoded when the field carries base64" do
      {body, content_type} = multipart([{"file", value: base64(@wav)}])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))
      assert rebuilt =~ ~s(filename="audio.wav")
      assert contains?(rebuilt, @wav)
      refute contains?(rebuilt, base64(@wav))
    end

    test "is rejected when the value is not audio at all" do
      {body, content_type} = multipart([{"file", value: "no soy audio"}])

      assert {:error, message} = AudioMultipart.canonicalize(body, content_type, %{})
      assert message =~ "missing audio"
    end
  end

  describe "the audio under another part name" do
    test "is renamed to file with its own filename and bytes" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper"},
          {"audio", filename: "llamada.mp3", content_type: "audio/mpeg", value: @mp3}
        ])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))

      assert rebuilt =~ ~s(name="file"; filename="llamada.mp3")
      assert rebuilt =~ ~s(content-type: audio/mpeg)
      assert contains?(rebuilt, @mp3)
      refute rebuilt =~ ~s(name="audio")
    end

    test "is renamed even when it arrives as a base64 text field" do
      {body, content_type} = multipart([{"upload", value: base64(@ogg)}])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))
      assert rebuilt =~ ~s(name="file"; filename="audio.ogg")
      assert contains?(rebuilt, @ogg)
    end
  end

  describe "a JSON body" do
    test "turns a base64 file into a multipart with its scalar fields" do
      payload = %{
        "model" => "whisper",
        "language" => "es",
        "response_format" => "text",
        "file" => base64(@ogg)
      }

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))

      assert rebuilt =~ ~s(name="model")
      assert rebuilt =~ "whisper"
      assert rebuilt =~ ~s(name="language")
      assert rebuilt =~ ~s(name="response_format")
      assert rebuilt =~ ~s(name="file"; filename="audio.ogg")
      assert contains?(rebuilt, @ogg)
    end

    test "accepts a data URL" do
      payload = %{"model" => "whisper", "file" => "data:audio/mpeg;base64," <> base64(@mp3)}

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))
      assert rebuilt =~ ~s(filename="audio.mp3")
      assert contains?(rebuilt, @mp3)
    end

    test "accepts the nested input_audio shape" do
      payload = %{
        "model" => "whisper",
        "input_audio" => %{"data" => base64(@wav), "format" => "wav"}
      }

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))
      assert rebuilt =~ ~s(name="file"; filename="audio.wav")
      assert contains?(rebuilt, @wav)
      refute rebuilt =~ "input_audio"
    end

    test "honours a client filename" do
      payload = %{"model" => "whisper", "file" => base64(@ogg), "filename" => "junta.ogg"}

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))
      assert rebuilt =~ ~s(name="file"; filename="junta.ogg")
      refute rebuilt =~ ~s(name="filename")
    end

    test "without audio is an error, not an empty upload" do
      assert {:error, message} =
               AudioMultipart.canonicalize(nil, nil, %{"model" => "whisper", "input" => "texto"})

      assert message =~ "missing audio"
    end

    test "with a base64 string that is not audio is an error" do
      assert {:error, _message} =
               AudioMultipart.canonicalize(nil, nil, %{"file" => Base.encode64("hola mundo")})
    end
  end

  describe "a body with no audio anywhere" do
    test "is an error so the caller answers 400 instead of calling upstream" do
      assert {:error, message} = AudioMultipart.canonicalize(nil, nil, %{})
      assert message =~ "missing audio"

      {body, content_type} = multipart([{"model", value: "whisper"}])
      assert {:error, _message} = AudioMultipart.canonicalize(body, content_type, %{})
    end
  end

  describe "shapes a real client sends" do
    test "webm/opus (MediaRecorder) is recognized and named" do
      webm = <<0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x02>>

      rebuilt =
        rebuilt(AudioMultipart.canonicalize(nil, nil, %{"file" => Base.encode64(webm)}))

      assert rebuilt =~ ~s(filename="audio.webm")
      assert contains?(rebuilt, webm)
    end

    test "a data URL carrying codecs parameters is decoded" do
      payload = %{"file" => "data:audio/ogg;codecs=opus;base64," <> base64(@ogg)}

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))
      assert contains?(rebuilt, @ogg)
    end

    test "urlsafe base64 is decoded" do
      bytes = <<"OggS", 0xFB, 0xFF>>
      encoded = Base.url_encode64(bytes)
      assert encoded =~ "_"

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, %{"file" => encoded}))
      assert contains?(rebuilt, bytes)
    end

    test "a duplicated urlencoded audio field uses the entry that is audio" do
      payload = %{"file" => ["no soy audio", base64(@ogg)]}

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))
      assert contains?(rebuilt, @ogg)
    end

    test "an empty file part does not hide the real audio under another name" do
      {body, content_type} =
        multipart([
          {"file", value: ""},
          {"audio", filename: "llamada.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      rebuilt = rebuilt(AudioMultipart.canonicalize(body, content_type, %{}))
      assert rebuilt =~ ~s(name="file"; filename="llamada.ogg")
      assert contains?(rebuilt, @ogg)
      # Exactly one `file` part: the empty one is gone, not left in front.
      assert length(String.split(rebuilt, ~s(name="file"))) == 2
    end

    test "a field NAME that could forge a header is dropped" do
      payload = %{
        "model" => "whisper",
        "file" => base64(@ogg),
        "x\"\r\ncontent-type: text/html\r\n\r\nINJECTED" => "1"
      }

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))

      refute rebuilt =~ "INJECTED"
      refute rebuilt =~ "text/html"
      assert length(String.split(rebuilt, "content-disposition")) == 3
    end

    test "a list field becomes the repeated [] part, never a silent drop" do
      payload = %{
        "model" => "whisper",
        "file" => base64(@ogg),
        "timestamp_granularities" => ["word", "segment"]
      }

      rebuilt = rebuilt(AudioMultipart.canonicalize(nil, nil, payload))

      assert rebuilt =~ ~s(name="timestamp_granularities[]")
      assert rebuilt =~ "word"
      assert rebuilt =~ "segment"
    end

    test "a multipart body it cannot parse is forwarded untouched, never a crash" do
      body =
        "--" <>
          @boundary <>
          "\r\ncontent-disposition: form-data\r\n\r\nx\r\n--" <> @boundary <> "--\r\n"

      content_type = "multipart/form-data; boundary=#{@boundary}"

      assert {:ok, ^body, ^content_type, :unchanged} =
               AudioMultipart.canonicalize(body, content_type, %{})
    end
  end

  describe "rewrite_model/3" do
    test "replaces the model value and keeps every other part and the audio bytes" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper-gateway"},
          {"language", value: "es"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      {rebuilt, rebuilt_type} = AudioMultipart.rewrite_model(body, content_type, "whisper")

      assert rebuilt_type =~ "multipart/form-data; boundary=tokengate-"
      assert rebuilt =~ ~s(name="model"\r\n\r\nwhisper)
      assert rebuilt =~ ~s(name="language"\r\n\r\nes)
      assert rebuilt =~ ~s(name="file"; filename="nota.ogg")
      assert contains?(rebuilt, @ogg)
      refute rebuilt =~ "whisper-gateway"
    end

    test "leaves the body untouched when it already carries the model" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      assert {^body, ^content_type} = AudioMultipart.rewrite_model(body, content_type, "whisper")
    end

    test "leaves a non-multipart body untouched" do
      assert {~s({"model":"x"}), "application/json"} =
               AudioMultipart.rewrite_model(~s({"model":"x"}), "application/json", "whisper")

      assert {nil, nil} = AudioMultipart.rewrite_model(nil, nil, "whisper")
    end

    test "adds the model part to a body that has none" do
      {body, content_type} =
        multipart([{"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}])

      {rebuilt, _content_type} = AudioMultipart.rewrite_model(body, content_type, "whisper")
      assert rebuilt =~ ~s(name="model"\r\n\r\nwhisper)
      assert contains?(rebuilt, @ogg)
    end
  end

  describe "rewrite_field/4" do
    test "replaces only that part and keeps the audio bytes" do
      {body, content_type} =
        multipart([
          {"model", value: "openai/whisper-large-v3"},
          {"response_format", value: "text"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      {rebuilt, _content_type} =
        AudioMultipart.rewrite_field(body, content_type, "response_format", "json")

      assert rebuilt =~ ~s(name="response_format"\r\n\r\njson)
      assert rebuilt =~ ~s(name="model"\r\n\r\nopenai/whisper-large-v3)
      assert contains?(rebuilt, @ogg)
      refute rebuilt =~ ~s(name="response_format"\r\n\r\ntext)
    end

    test "leaves the body untouched when the part already carries the value" do
      {body, content_type} =
        multipart([
          {"response_format", value: "json"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      assert {^body, ^content_type} =
               AudioMultipart.rewrite_field(body, content_type, "response_format", "json")
    end

    test "adds the part when the body has none" do
      {body, content_type} =
        multipart([{"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}])

      {rebuilt, _content_type} =
        AudioMultipart.rewrite_field(body, content_type, "response_format", "json")

      assert rebuilt =~ ~s(name="response_format"\r\n\r\njson)
      assert contains?(rebuilt, @ogg)
    end

    test "rewrite_model/3 is the same operation on the model part" do
      {body, content_type} =
        multipart([
          {"model", value: "whisper"},
          {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @ogg}
        ])

      {rebuilt, rebuilt_type} = AudioMultipart.rewrite_model(body, content_type, "whisper-1")

      assert rebuilt_type =~ "multipart/form-data; boundary=tokengate-"
      assert rebuilt =~ ~s(name="model"\r\n\r\nwhisper-1)
      assert contains?(rebuilt, @ogg)
    end
  end

  describe "multipart_upload?/1" do
    test "only the dialects that post the body as multipart" do
      assert AudioMultipart.multipart_upload?("openai")
      assert AudioMultipart.multipart_upload?("openrouter")
      refute AudioMultipart.multipart_upload?("dashscope")
      refute AudioMultipart.multipart_upload?("token_plan")
      refute AudioMultipart.multipart_upload?("typesafe")
      refute AudioMultipart.multipart_upload?(nil)
    end
  end
end
