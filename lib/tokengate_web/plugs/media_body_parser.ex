defmodule TokengateWeb.Plugs.MediaBodyParser do
  @moduledoc """
  Raw-body capture for non-JSON requests on the proxy API (`/v1`).

  The stock `Plug.Parsers` multipart parser streams every file part to a
  temp file and exposes a `%Plug.Upload{}`; the raw bytes are gone
  afterwards, so the request cannot be rebuilt (a `%Plug.Upload{}` has no
  encoder, and re-encoding the parsed fields would not reproduce the
  original body). The proxy is a passthrough: the upstream must receive the
  exact bytes the client sent.

  This plug runs in the endpoint BEFORE `Plug.Parsers` and only for the
  configured path prefixes (default `/v1/`). For a non-JSON content-type it:

    * reads the whole body once and stashes the bytes plus the original
      `content-type` in `conn.private` (see `raw_body_key/0` and
      `raw_content_type_key/0`) so `ProxyController` can forward them
      byte-for-byte;
    * parses `multipart/form-data` fields into `body_params` (via the stock
      `:plug_multipart` low-level parser) so routing, limits and the
      inflight registry keep working — they read `payload["model"]`. A file
      part is exposed as a `Tokengate.Proxy.MediaFile` (metadata only: the
      bytes live once, in the captured raw body);
    * parses `application/x-www-form-urlencoded` the same way.

  JSON bodies are left alone (`Plug.Parsers` handles them as always), as
  are other methods, other prefixes, and requests whose `body_params` were
  already fetched (the adapter-level test harness and any caller that ran
  a parser of its own).
  """

  @behaviour Plug

  # Same cap as the endpoint's `Plug.Parsers`; kept here because this plug
  # reads the body before that plug ever sees it.
  @max_body_bytes 10_000_000
  @multipart_subtypes ~w(form-data mixed)

  @raw_body_key :tokengate_raw_body
  @raw_content_type_key :tokengate_raw_content_type

  @doc """
  The `conn.private` key holding the captured raw request body (a binary).
  """
  def raw_body_key, do: @raw_body_key

  @doc """
  The `conn.private` key holding the request's original `content-type` header.
  """
  def raw_content_type_key, do: @raw_content_type_key

  @impl true
  def init(opts), do: Keyword.get(opts, :prefixes, ["/v1/"])

  @impl true
  def call(%Plug.Conn{method: method} = conn, prefixes)
      when method in ~w(POST PUT PATCH DELETE) do
    if prefixed?(conn, prefixes) and unfetched?(conn) do
      capture(conn)
    else
      conn
    end
  end

  def call(conn, _prefixes), do: conn

  defp unfetched?(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: true
  defp unfetched?(_conn), do: false

  defp prefixed?(conn, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(conn.request_path, &1))
  end

  defp capture(conn) do
    case content_type(conn) do
      {:json, _value} ->
        conn

      {:multipart, boundary} ->
        read_and_store(conn, fn body -> decode_parts(body, boundary) end)

      {:urlencoded, _value} ->
        read_and_store(conn, fn body -> Plug.Conn.Query.decode(body) end)

      {:other, _value} ->
        read_and_store(conn, fn _body -> %{} end)

      :missing ->
        conn
    end
  end

  # No content-type is what `Plug.Parsers` treats as "no parser applies":
  # leave the request untouched instead of guessing one.
  defp content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [value] -> classify(value)
      _ -> :missing
    end
  end

  defp classify(value) do
    case Plug.Conn.Utils.media_type(value) do
      {:ok, "application", "x-www-form-urlencoded", _params} ->
        {:urlencoded, value}

      {:ok, "application", subtype, _params} ->
        if subtype == "json" or String.ends_with?(subtype, "+json") do
          {:json, value}
        else
          {:other, value}
        end

      {:ok, "multipart", subtype, params} when subtype in @multipart_subtypes ->
        case params do
          %{"boundary" => boundary} -> {:multipart, boundary}
          _ -> {:other, value}
        end

      _ ->
        {:other, value}
    end
  end

  defp read_and_store(conn, params_fun) do
    case read_full_body(conn) do
      {:ok, body, conn} ->
        params =
          try do
            params_fun.(body)
          rescue
            # A malformed body must not crash the endpoint: the capture is
            # still forwarded raw, and the controller's own gates (starting
            # with `model is required`) reject what the parse could not
            # describe.
            _ -> %{}
          end

        conn
        |> Plug.Conn.put_private(@raw_body_key, body)
        |> Plug.Conn.put_private(@raw_content_type_key, request_content_type(conn))
        |> Map.put(:body_params, params)

      {:error, :too_large} ->
        respond(conn, 413, "Request body too large", "request_too_large")

      {:error, _reason} ->
        respond(conn, 400, "Malformed request body", "bad_request")
    end
  end

  # Reads the whole body, accumulating chunks and enforcing the total cap
  # here: `:length` in `read_body/2` caps a single call, not the total.
  defp read_full_body(conn, acc \\ [], total \\ 0) do
    opts = [length: @max_body_bytes, read_length: 1_000_000]

    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        finish_body(acc, chunk, total, conn)

      {:more, chunk, conn} ->
        total = total + byte_size(chunk)

        if total > @max_body_bytes do
          {:error, :too_large}
        else
          read_full_body(conn, [acc | chunk], total)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_body(acc, chunk, total, conn) do
    if total + byte_size(chunk) > @max_body_bytes do
      {:error, :too_large}
    else
      {:ok, IO.iodata_to_binary([acc | chunk]), conn}
    end
  end

  defp request_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [value] -> value
      _ -> nil
    end
  end

  # Multipart bodies are small (audio clips, a few megabytes at most) and the
  # proxy needs the bytes in memory to forward them — decoding the parts adds
  # no copy of the file (the raw body stays the single source of the bytes).
  defp decode_parts(body, boundary) do
    body
    |> collect_parts(boundary)
    |> Enum.reduce(Plug.Conn.Query.decode_init(), fn {name, value}, acc ->
      Plug.Conn.Query.decode_each({name, value}, acc)
    end)
    |> Plug.Conn.Query.decode_done()
  end

  defp collect_parts(body, boundary) do
    case :plug_multipart.parse_headers(body, boundary) do
      {:ok, headers, rest} ->
        {value, rest} = decode_part(headers, rest, boundary)
        [{part_name(headers), value} | collect_parts(rest, boundary)]

      _ ->
        # `{:done, epilogue}` is the normal end; a truncated body (no closing
        # boundary) stops here too — the rescue in `read_and_store/2` turns a
        # partial parse into `%{}`.
        []
    end
  end

  defp decode_part(headers, rest, boundary) do
    {raw_value, rest} =
      case :plug_multipart.parse_body(rest, boundary) do
        {:ok, value} -> {value, ""}
        {:ok, value, rest} -> {value, rest}
        {:done, value} -> {value, ""}
        {:done, value, rest} -> {value, rest}
      end

    case :plug_multipart.form_data(headers) do
      {_kind, _name} ->
        {raw_value, rest}

      {_kind, _name, filename, content_type, _encoding} ->
        {%Tokengate.Proxy.MediaFile{
           filename: filename,
           content_type: content_type,
           size: byte_size(raw_value)
         }, rest}
    end
  end

  defp part_name(headers) do
    case :plug_multipart.form_data(headers) do
      {_kind, name} -> name
      {_kind, name, _filename, _content_type, _encoding} -> name
    end
  end

  defp respond(conn, status, message, code) do
    body =
      Jason.encode!(%{
        "error" => %{"message" => message, "type" => "invalid_request_error", "code" => code}
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
