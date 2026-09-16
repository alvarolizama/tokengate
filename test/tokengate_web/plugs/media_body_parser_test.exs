defmodule TokengateWeb.Plugs.MediaBodyParserTest do
  @moduledoc """
  Unit tests for the raw multipart/urlencoded capture that feeds the proxy's
  passthrough: the bytes must survive the parse, and the form fields must
  keep feeding routing (`model`).
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.MediaFile
  alias TokengateWeb.Plugs.MediaBodyParser

  @boundary "plug-boundary-test"

  defp multipart_body do
    IO.iodata_to_binary([
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="model"\r\n\r\n),
      "whisper-1\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="language"\r\n\r\n),
      "es\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="audio.wav"\r\n),
      "content-type: audio/wav\r\n\r\n",
      <<0x52, 0x49, 0xFF, 0x00>>,
      "\r\n",
      "--",
      @boundary,
      "--\r\n"
    ])
  end

  defp conn_with(body, content_type) do
    :post
    |> Plug.Test.conn("/v1/audio/transcriptions", body)
    |> Plug.Conn.put_req_header("content-type", content_type)
  end

  defp multipart_conn(body \\ nil) do
    conn_with(body || multipart_body(), "multipart/form-data; boundary=#{@boundary}")
  end

  test "captures the raw body byte-for-byte and the original content-type" do
    body = multipart_body()
    conn = MediaBodyParser.call(multipart_conn(body), ["/v1/"])

    assert conn.private[MediaBodyParser.raw_body_key()] == body

    assert conn.private[MediaBodyParser.raw_content_type_key()] ==
             "multipart/form-data; boundary=#{@boundary}"
  end

  test "parses the form fields so routing keeps working" do
    conn = MediaBodyParser.call(multipart_conn(), ["/v1/"])

    assert conn.body_params["model"] == "whisper-1"
    assert conn.body_params["language"] == "es"
  end

  test "a file part is MediaFile metadata — no temp file is written" do
    conn = MediaBodyParser.call(multipart_conn(), ["/v1/"])

    assert %MediaFile{filename: "audio.wav", content_type: "audio/wav", size: 4} =
             conn.body_params["file"]
  end

  test "a JSON body passes through untouched for Plug.Parsers" do
    conn =
      conn_with(~s({"model": "x"}), "application/json")

    assert MediaBodyParser.call(conn, ["/v1/"]) == conn
  end

  test "a urlencoded body is captured and parsed" do
    conn =
      conn_with("model=whisper-1&language=es", "application/x-www-form-urlencoded")

    conn = MediaBodyParser.call(conn, ["/v1/"])

    assert conn.private[MediaBodyParser.raw_body_key()] == "model=whisper-1&language=es"
    assert conn.body_params["model"] == "whisper-1"
  end

  test "a request outside the prefixes is left alone" do
    conn =
      :post
      |> Plug.Test.conn("/health", "irrelevant")
      |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=x")

    assert MediaBodyParser.call(conn, ["/v1/"]) == conn
  end

  test "a request whose body_params were already fetched is left alone" do
    conn = %{multipart_conn() | body_params: %{"model" => "already"}}

    assert MediaBodyParser.call(conn, ["/v1/"]) == conn
  end
end
