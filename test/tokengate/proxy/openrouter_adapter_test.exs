defmodule Tokengate.Proxy.OpenRouterAdapterTest do
  @moduledoc """
  The OpenRouter dialect deviation on the STT surface: `response_format=text` is
  rejected by the endpoint with a 400, so the adapter asks for `json` and answers
  the transcript as `text/plain`. Everything else crosses untouched.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Proxy.OpenRouterAdapter
  alias Tokengate.Proxy.RawResponse

  @port 41235
  @boundary "or-boundary-test"
  @audio <<0x52, 0x49, 0xFF, 0x00, 0x46, 0x4D>>

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:captured, conn.request_path, body, conn.req_headers})
      end

      json(conn, 200, %{
        "text" => "hola mundo",
        "usage" => %{"cost" => 0.0001, "input_tokens" => 3, "output_tokens" => 2}
      })
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end

  setup do
    :persistent_term.put({TestPlug, :test_pid}, self())
    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})

    {:ok,
     provider: %{base_url: "http://localhost:#{@port}"},
     credential: %{api_key_encrypted: "sk-or-test"}}
  end

  defp multipart(parts) do
    body =
      parts
      |> Enum.map(&encode/1)
      |> Enum.concat([["--", @boundary, "--\r\n"]])
      |> IO.iodata_to_binary()

    {body, "multipart/form-data; boundary=#{@boundary}"}
  end

  defp encode({name, opts}) do
    filename = Keyword.get(opts, :filename)
    content_type = Keyword.get(opts, :content_type)
    value = Keyword.fetch!(opts, :value)

    disposition =
      case filename do
        nil -> ~s(content-disposition: form-data; name="#{name}")
        file -> ~s(content-disposition: form-data; name="#{name}"; filename="#{file}")
      end

    type = if content_type, do: ["content-type: ", content_type, "\r\n"], else: []

    ["--", @boundary, "\r\n", disposition, "\r\n", type, "\r\n", value, "\r\n"]
  end

  defp stt_body(response_format) do
    multipart([
      {"model", value: "openai/whisper-large-v3"},
      {"response_format", value: response_format},
      {"file", filename: "nota.ogg", content_type: "audio/ogg", value: @audio}
    ])
  end

  describe "service_post/5 on :stt" do
    test "asks for json and answers the transcript as plain text", %{
      provider: provider,
      credential: credential
    } do
      {body, content_type} = stt_body("text")

      assert {:ok, %RawResponse{} = response, _latency, _headers} =
               OpenRouterAdapter.service_post(
                 provider,
                 credential,
                 :stt,
                 %{"model" => "openai/whisper-large-v3", "response_format" => "text"},
                 raw_body: body,
                 content_type: content_type
               )

      assert response.body == "hola mundo"
      assert response.content_type =~ "text/plain"

      assert_receive {:captured, "/audio/transcriptions", sent, headers}
      assert sent =~ ~s(name="response_format"\r\n\r\njson)
      refute sent =~ ~s(name="response_format"\r\n\r\ntext)
      # The audio and the model travel as the client sent them.
      assert :binary.match(sent, @audio) != :nomatch
      assert sent =~ ~s(name="model"\r\n\r\nopenai/whisper-large-v3)
      assert {"content-type", "multipart/form-data; boundary=" <> _} = keyfind(headers)
    end

    test "a json request gets the field replaced before encoding", %{
      provider: provider,
      credential: credential
    } do
      assert {:ok, %RawResponse{body: "hola mundo"}, _latency, _headers} =
               OpenRouterAdapter.service_post(
                 provider,
                 credential,
                 :stt,
                 %{
                   "model" => "openai/whisper-large-v3",
                   "response_format" => "text",
                   "input_audio" => %{"data" => "AAAA", "format" => "wav"}
                 },
                 []
               )

      assert_receive {:captured, "/audio/transcriptions", sent, headers}
      decoded = Jason.decode!(sent)
      assert decoded["response_format"] == "json"
      assert decoded["model"] == "openai/whisper-large-v3"
      assert {"content-type", "application/json"} = keyfind(headers)
    end

    test "json and verbose_json cross untouched and keep the decoded body", %{
      provider: provider,
      credential: credential
    } do
      for format <- ["json", "verbose_json"] do
        {body, content_type} = stt_body(format)

        assert {:ok, %{"text" => "hola mundo"}, _latency, _headers} =
                 OpenRouterAdapter.service_post(
                   provider,
                   credential,
                   :stt,
                   %{"model" => "openai/whisper-large-v3", "response_format" => format},
                   raw_body: body,
                   content_type: content_type
                 )

        assert_receive {:captured, "/audio/transcriptions", sent, headers}
        assert sent == body
        assert {"content-type", ^content_type} = keyfind(headers)
      end
    end
  end

  defp keyfind(headers) do
    Enum.find(headers, fn {key, _value} -> key == "content-type" end)
  end
end
