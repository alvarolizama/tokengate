defmodule Tokengate.Proxy.AudioMultipart do
  @moduledoc """
  Canonical `multipart/form-data` body for a speech-to-text upload.

  The proxy forwards the client's bytes untouched (`OpenAIAdapter.post_payload/5`),
  which is exactly right when the client built a valid multipart body with a real
  `file` part. A client that sends the audio as JSON + base64, as a plain text
  field, or as a file part WITHOUT a filename gets the upstream's schema error —
  FastAPI answers `422` naming `body.file` — a rejection that names nothing and
  already spent the call.

  This module rebuilds the body only when it is NOT already canonical:

    * a `file` part with no `filename` (the audio arrived as a text field);
    * the audio under another part name (`audio`, `upload`, `data`, `input_audio`);
    * a JSON or urlencoded body whose audio field holds base64 — plain, urlsafe or
      a data URL — including the nested `input_audio: {"data": …, "format": …}`.

  A canonical body is returned unchanged so the caller can keep the byte-for-byte
  passthrough. When no audio can be recovered the result is `{:error, message}`,
  which the proxy answers as a precise `400 missing_audio` instead of forwarding a
  request the upstream is going to reject anyway. A multipart body this module
  cannot parse is also forwarded untouched: it only judges what it can read.

  It applies only to the dialects that post the client's body as multipart — see
  `multipart_upload?/1`. DashScope and the Alibaba Token Plan take the audio as a
  JSON field (`audio_url`, `url`), so their bodies are never judged here.

  The audio always comes from the RAW bytes (multipart) or from the decoded base64
  field: `%Tokengate.Proxy.MediaFile{}` carries metadata only.
  """

  @audio_fields ~w(file audio upload data input_audio)

  # Dialects whose `service_post` forwards the client's body as multipart and
  # therefore need a real `file` part. Everything else has its own wire and its
  # own audio sources.
  @multipart_dialects ~w(openai openrouter)

  # Part names are header values: anything outside this set is dropped, never
  # escaped, because an injected CRLF would forge a part header.
  @safe_name ~r/\A[A-Za-z0-9_.\-\[\]]+\z/

  @type outcome ::
          {:ok, binary() | nil, String.t() | nil, :unchanged | :rebuilt}
          | {:error, String.t()}

  @doc """
  True when the provider's dialect needs a multipart body for its STT service.
  """
  @spec multipart_upload?(String.t() | nil) :: boolean()
  def multipart_upload?(dialect), do: dialect in @multipart_dialects

  @doc """
  Returns the body the upstream must receive and whether it was rebuilt.

  `:unchanged` keeps the caller's exact bytes and content-type. `:rebuilt` carries
  a NEW multipart body (and its own boundary) built from the recovered audio.

  ## Examples

      iex> Tokengate.Proxy.AudioMultipart.canonicalize(nil, nil, %{"model" => "whisper"})
      {:error, "missing audio: send multipart/form-data with a \\"file\\" part (audio bytes and filename), or a base64 audio string in file/audio/upload/data/input_audio"}

  """
  @spec canonicalize(binary() | nil, String.t() | nil, map() | nil) :: outcome
  def canonicalize(raw_body, content_type, payload) when is_binary(raw_body) do
    case boundary(content_type) do
      {:ok, boundary} -> from_multipart(raw_body, content_type, boundary)
      :error -> from_fields(payload)
    end
  end

  def canonicalize(_raw_body, _content_type, payload), do: from_fields(payload)

  @doc "The message a caller returns when no audio could be recovered."
  @spec missing_audio() :: String.t()
  def missing_audio do
    "missing audio: send multipart/form-data with a \"file\" part (audio bytes and " <>
      "filename), or a base64 audio string in file/audio/upload/data/input_audio"
  end

  ## Multipart bodies ##########################################################

  defp from_multipart(raw_body, content_type, boundary) do
    case parse(raw_body, boundary) do
      :error -> {:ok, raw_body, content_type, :unchanged}
      [] -> {:error, missing_audio()}
      parts -> canonical_parts(parts, raw_body, content_type)
    end
  end

  # A real file part wins and costs nothing: the client built it right, so the
  # bytes and the boundary travel as received.
  defp canonical_parts(parts, raw_body, content_type) do
    case Enum.find(parts, &(&1.name == "file")) do
      %{filename: filename} when is_binary(filename) and filename != "" ->
        {:ok, raw_body, content_type, :unchanged}

      %{value: value} = file ->
        # A `file` field that carries no audio (empty, a path, a stray string)
        # must not block the real audio sitting under another name.
        case recover(value) do
          nil -> rebuild_alternate(parts)
          bytes -> rebuild(parts, file, bytes, nil)
        end

      nil ->
        rebuild_alternate(parts)
    end
  end

  defp rebuild_alternate(parts) do
    case alternate(parts) do
      nil -> {:error, missing_audio()}
      {part, bytes} -> rebuild(parts, part, bytes, part.filename)
    end
  end

  # The audio under another name: only a part whose value really decodes to audio
  # qualifies, so a stray `format=mp3` text field never becomes the upload.
  defp alternate(parts) do
    Enum.find_value(parts, fn part ->
      if part.name != "file" and part.name in @audio_fields do
        case recover(part.value) do
          nil -> nil
          bytes -> {part, bytes}
        end
      end
    end)
  end

  defp rebuild(parts, audio_part, bytes, filename) do
    # A `file` part that is not the one being rebuilt is dropped: leaving an
    # empty/foreign `file` before the real one would make the upstream take the
    # wrong part.
    parts = Enum.reject(parts, &(&1.name == "file" and &1 != audio_part))
    filename = if present?(filename), do: filename, else: "audio." <> extension(bytes)

    parts =
      Enum.map(parts, fn part ->
        if part == audio_part do
          %{
            part
            | name: "file",
              filename: filename,
              content_type: part.content_type || mime(filename),
              value: bytes
          }
        else
          part
        end
      end)

    {body, content_type} = encode(parts)
    {:ok, body, content_type, :rebuilt}
  end

  @doc """
  Replaces the `model` part when the body carries a different one.

  A canonical multipart is forwarded byte-for-byte, so its `model` field is the
  CLIENT's string: the payload rewrite every JSON surface gets never reaches the
  wire. When the lane's upstream id differs from the name the client sent, this
  swaps that one value so STT maps the model like chat/TTS/embeddings do — same
  parts, same bytes, one field corrected.

  Returns the body untouched when it already carries `model`, when the
  content-type is not multipart, or when the body cannot be parsed.
  """
  @spec rewrite_model(binary() | nil, String.t() | nil, String.t() | nil) ::
          {binary() | nil, String.t() | nil}
  def rewrite_model(raw_body, content_type, model)
      when is_binary(raw_body) and is_binary(model) do
    with {:ok, boundary} <- boundary(content_type),
         parts when parts != [] <- parse(raw_body, boundary),
         false <- carries_model?(parts, model) do
      encode(replace_model(parts, model))
    else
      _ -> {raw_body, content_type}
    end
  end

  def rewrite_model(raw_body, content_type, _model), do: {raw_body, content_type}

  defp carries_model?(parts, model) do
    Enum.any?(parts, &(&1.name == "model" and &1.value == model))
  end

  defp replace_model(parts, model) do
    case Enum.find_index(parts, &(&1.name == "model")) do
      nil -> parts ++ [%{name: "model", filename: nil, content_type: nil, value: model}]
      index -> List.update_at(parts, index, &%{&1 | value: model})
    end
  end

  defp encode(parts) do
    boundary = new_boundary()

    body =
      parts
      |> Enum.map(fn part ->
        encode_part(boundary, part.name, part.filename, part.content_type, part.value)
      end)
      |> Enum.concat([["--", boundary, "--\r\n"]])
      |> IO.iodata_to_binary()

    {body, "multipart/form-data; boundary=#{boundary}"}
  end

  ## Parsed fields (JSON / urlencoded) #########################################

  defp from_fields(payload) when is_map(payload) do
    case audio_field(payload) do
      nil -> {:error, missing_audio()}
      {_field, bytes} -> build_from_fields(payload, bytes)
    end
  end

  defp from_fields(_payload), do: {:error, missing_audio()}

  defp audio_field(payload) do
    Enum.find_value(@audio_fields, fn field ->
      case Map.get(payload, field) do
        value when is_binary(value) -> tuple(field, recover(value))
        # A duplicated urlencoded field arrives as a list: take the first entry
        # that really is audio.
        values when is_list(values) -> tuple(field, first_audio(values))
        %{} = nested -> tuple(field, nested |> Map.get("data") |> recover())
        _ -> nil
      end
    end)
  end

  defp first_audio(values) do
    Enum.find_value(values, fn value -> if is_binary(value), do: recover(value) end)
  end

  defp tuple(_field, nil), do: nil
  defp tuple(field, bytes), do: {field, bytes}

  defp build_from_fields(payload, bytes) do
    boundary = new_boundary()
    filename = filename_from(payload, bytes)

    body =
      payload
      |> Enum.reject(fn {key, _value} -> key in @audio_fields or key == "filename" end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.flat_map(fn {key, value} -> field_parts(boundary, key, value) end)
      |> Enum.concat([encode_part(boundary, "file", filename, mime(filename), bytes)])
      |> Enum.concat([["--", boundary, "--\r\n"]])
      |> IO.iodata_to_binary()

    {:ok, body, "multipart/form-data; boundary=#{boundary}", :rebuilt}
  end

  # Scalars become one part; a list of scalars becomes the repeated `key[]` the
  # OpenAI surface expects (`timestamp_granularities[]`), never a silent drop.
  defp field_parts(boundary, key, value) when is_list(value) do
    if value != [] and Enum.all?(value, &scalar?/1) do
      Enum.map(value, &encode_part(boundary, key <> "[]", nil, nil, to_string(&1)))
    else
      []
    end
  end

  defp field_parts(boundary, key, value) do
    if scalar?(value), do: [encode_part(boundary, key, nil, nil, to_string(value))], else: []
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp filename_from(payload, bytes) do
    case Map.get(payload, "filename") do
      name when is_binary(name) -> if present?(name), do: sane(name), else: default_name(bytes)
      _ -> default_name(bytes)
    end
  end

  defp default_name(bytes), do: "audio." <> extension(bytes)

  # A filename is a header value: drop anything that could break the part's
  # `content-disposition` line and keep the leaf name.
  defp sane(name) do
    name
    |> String.replace(~r/[\r\n"]/, "")
    |> Path.basename()
  end

  ## Multipart encoding ########################################################

  # Field NAME and filename are client input: both are sanitized, and a name that
  # cannot be a safe header token is DROPPED (an injected CRLF would otherwise
  # forge a part header, and this body travels upstream with the gateway key).
  defp encode_part(boundary, name, filename, content_type, value) do
    case safe_name(name) do
      nil ->
        []

      name ->
        disposition =
          case filename do
            file when is_binary(file) and file != "" ->
              ~s(content-disposition: form-data; name="#{name}"; filename="#{sane(file)}")

            _ ->
              ~s(content-disposition: form-data; name="#{name}")
          end

        type_header =
          case content_type do
            type when is_binary(type) and type != "" -> ["content-type: ", type, "\r\n"]
            _ -> []
          end

        ["--", boundary, "\r\n", disposition, "\r\n", type_header, "\r\n", value, "\r\n"]
    end
  end

  defp safe_name(name) when is_binary(name) do
    if Regex.match?(@safe_name, name), do: name
  end

  defp safe_name(_name), do: nil

  ## Multipart parsing #########################################################

  # Mirrors `Tokengate.Proxy.MultipartFile` (the same low-level Plug parser the
  # body plug uses) but keeps EVERY part, because rebuilding must not drop the
  # form fields the upstream needs (model, language, response_format…).
  #
  # `:error` means "not parseable", never "no audio": the caller forwards those
  # bytes untouched instead of turning a junk body into a crash.
  defp parse(body, boundary) do
    collect(body, boundary)
  rescue
    _ -> :error
  end

  defp collect(body, boundary) do
    case :plug_multipart.parse_headers(body, boundary) do
      {:ok, headers, rest} ->
        with {part, rest} <- part(headers, rest, boundary),
             parts when is_list(parts) <- collect(rest, boundary) do
          [part | parts]
        else
          _ -> :error
        end

      {:done, _epilogue} ->
        []

      _other ->
        :error
    end
  end

  defp part(headers, rest, boundary) do
    case part_body(rest, boundary) do
      :error ->
        :error

      {value, rest} ->
        case :plug_multipart.form_data(headers) do
          {_kind, name} ->
            {%{name: name, filename: nil, content_type: nil, value: value}, rest}

          {_kind, name, filename, content_type, _encoding} ->
            {%{name: name, filename: filename, content_type: content_type, value: value}, rest}

          _other ->
            :error
        end
    end
  end

  # `form_data/1` returns `false` for a part with no `content-disposition` (a
  # malformed body) and raises on an unparsable one: both are the caller's
  # problem, not a reason to crash the endpoint.
  defp part_body(rest, boundary) do
    case :plug_multipart.parse_body(rest, boundary) do
      {:ok, value} -> {value, ""}
      {:ok, value, rest} -> {value, rest}
      {:done, value} -> {value, ""}
      {:done, value, rest} -> {value, rest}
      :done -> {<<>>, ""}
      _other -> :error
    end
  end

  defp boundary(content_type) when is_binary(content_type) do
    case Plug.Conn.Utils.media_type(content_type) do
      {:ok, "multipart", _subtype, %{"boundary" => boundary}} when boundary != "" ->
        {:ok, boundary}

      _ ->
        :error
    end
  end

  defp boundary(_content_type), do: :error

  defp new_boundary do
    "tokengate-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  ## Audio detection ###########################################################

  # Raw bytes that already look like audio pass through; anything else is tried
  # as base64 (a data URL included). Both ends are checked against the container
  # magic so a text field named `file` cannot become a bogus upload.
  defp recover(value) when is_binary(value) and value != "" do
    cond do
      audio?(value) -> value
      String.valid?(value) -> decode_base64(value)
      true -> nil
    end
  end

  defp recover(_value), do: nil

  defp decode_base64(value) do
    with {:ok, body} <- strip_data_url(value),
         encoded = String.replace(body, ~r/\s+/, ""),
         {:ok, bytes} <- decode64(encoded),
         true <- audio?(bytes) do
      bytes
    else
      _ -> nil
    end
  end

  # `data:audio/ogg;codecs=opus;base64,<payload>` — the media type may carry
  # parameters, so the marker is the `;base64` flag, not the exact header.
  defp strip_data_url("data:" <> rest = value) do
    case String.split(rest, ",", parts: 2) do
      [header, payload] ->
        if header |> String.downcase() |> String.contains?(";base64"),
          do: {:ok, payload},
          else: {:error, value}

      _ ->
        {:error, value}
    end
  end

  defp strip_data_url(value), do: {:ok, value}

  # Standard and urlsafe alphabets, padded and unpadded: browsers and JS clients
  # disagree on which one they emit.
  defp decode64(encoded) do
    decoders = [
      fn -> Base.decode64(encoded) end,
      fn -> Base.decode64(encoded, padding: false) end,
      fn -> Base.url_decode64(encoded) end,
      fn -> Base.url_decode64(encoded, padding: false) end
    ]

    Enum.find_value(decoders, :error, fn decode ->
      case decode.() do
        {:ok, bytes} -> {:ok, bytes}
        :error -> nil
      end
    end)
  end

  defp audio?("OggS" <> _rest), do: true
  defp audio?("ID3" <> _rest), do: true
  defp audio?("fLaC" <> _rest), do: true
  defp audio?("#!AMR" <> _rest), do: true
  defp audio?("RIFF" <> <<_size::binary-size(4), "WAVE", _rest::binary>>), do: true
  defp audio?("FORM" <> <<_size::binary-size(4), "AIFF", _rest::binary>>), do: true
  defp audio?(<<_size::binary-size(4), "ftyp", _rest::binary>>), do: true
  # EBML — the container `MediaRecorder` produces for `audio/webm;codecs=opus`.
  defp audio?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true
  defp audio?(<<0xFF, second, _rest::binary>>) when second in 0xE0..0xFF, do: true
  defp audio?(_value), do: false

  defp extension(bytes) do
    cond do
      match?("OggS" <> _, bytes) -> "ogg"
      match?("ID3" <> _, bytes) -> "mp3"
      match?("fLaC" <> _, bytes) -> "flac"
      match?("#!AMR" <> _, bytes) -> "amr"
      match?("RIFF" <> <<_::binary-size(4), "WAVE", _::binary>>, bytes) -> "wav"
      match?("FORM" <> <<_::binary-size(4), "AIFF", _::binary>>, bytes) -> "aiff"
      match?(<<_::binary-size(4), "ftyp", _::binary>>, bytes) -> "m4a"
      match?(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>, bytes) -> "webm"
      match?(<<0xFF, _second, _::binary>>, bytes) -> "mp3"
      true -> "bin"
    end
  end

  defp mime(filename) do
    case Path.extname(filename) do
      ".ogg" -> "audio/ogg"
      ".opus" -> "audio/ogg"
      ".mp3" -> "audio/mpeg"
      ".wav" -> "audio/wav"
      ".flac" -> "audio/flac"
      ".aiff" -> "audio/aiff"
      ".m4a" -> "audio/mp4"
      ".mp4" -> "audio/mp4"
      ".amr" -> "audio/amr"
      ".webm" -> "audio/webm"
      _ -> "application/octet-stream"
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
