defmodule Tokengate.Proxy.ServiceUsage do
  @moduledoc """
  La CANTIDAD facturable de una llamada, por tipo de modelo.

  `CostCalculator` multiplica una cantidad por un precio unitario. Para los
  tipos de token esa cantidad son los contadores de `usage`; para los seis
  servicios de media hay que sacarla de OTRO sitio, porque su respuesta no trae
  tokens: un número de imágenes, unos segundos de vídeo o de audio, unos
  caracteres sintetizados.

  Este módulo es ese extractor. Devuelve un MAPA de cantidades por unidad —
  no una sola — porque la unidad es una decisión del LANE
  (`model_providers.pricing_unit`), no del tipo: un proveedor puede cobrar la
  imagen fija y otro por megapíxel, y ambos son `model_type: "image"`. El
  caller toma la cantidad de la unidad que ese lane declaró.

  ## Qué es reportado y qué es estimado

  El orden es siempre el mismo: **lo que el upstream reportó gana**; si calla,
  se usa lo que la propia request dice (nº de imágenes pedidas, tamaño, texto
  de entrada); y si no hay señal, la cantidad es **0** — que multiplicada por
  cualquier precio da `$0`. Nunca se inventa un número.

  La única estimación que no sale de la request es la **duración de audio**
  (`stt`/`video` emitidos como bytes o como data URL): se deriva del tamaño a
  128 kbps, que es el bitrate nominal de los formatos que estos endpoints
  aceptan. Está documentada en `audio_seconds_from_bytes/1` y es una
  aproximación — por eso el coste reportado por el upstream, cuando existe,
  siempre la pisa.
  """

  # Bitrate nominal para estimar la duración de un audio cuando nadie la
  # reporta: 128 kbps es el modo más común de los formatos que aceptan los
  # endpoints de transcripción (mp3/m4a/aac estéreo).
  @nominal_bits_per_second 128_000

  @doc """
  Las cantidades facturables de una llamada, por unidad.

  Siempre incluye `"per_request" => 1` (la llamada ocurrió y se cobró), más lo
  que el tipo sepa extraer.

      iex> Tokengate.Proxy.ServiceUsage.quantities("image", %{"n" => 3}, %{})
      %{"per_request" => 1, "per_image" => 3, "per_megapixel" => 0}

      iex> Tokengate.Proxy.ServiceUsage.quantities("tts", %{"input" => "hola"}, %{})
      %{"per_request" => 1, "per_1k_characters" => 4}
  """
  @spec quantities(String.t() | nil, map(), map()) :: %{String.t() => number() | Decimal.t()}
  def quantities(type, payload, body) do
    Map.merge(%{"per_request" => 1}, per_type(type, payload, body))
  end

  @doc "La cantidad para una unidad concreta, o `nil` cuando no aplica."
  @spec quantity(String.t() | nil, String.t(), map(), map()) :: number() | Decimal.t() | nil
  def quantity(type, unit, payload, body) do
    Map.get(quantities(type, payload, body), unit)
  end

  ## Por tipo ##################################################################

  # Chat, embeddings, decisiones y rerank se facturan por tokens: lo que
  # reported el upstream, o el estimado de la request (mismo criterio que ya
  # usaba el proxy para estos caminos).
  defp per_type(type, payload, body) when type in ["llm", "embedding", "decision", "rerank"] do
    tokens = reported_tokens(body) || estimated_tokens(payload)
    %{"per_1m_tokens" => tokens, "per_1k_tokens" => tokens}
  end

  defp per_type("image", payload, body) do
    count = image_count(body) || request_count(payload)

    %{
      "per_image" => count,
      "per_megapixel" => megapixels(payload, count)
    }
  end

  # Vídeo y música se cobran por segundo de material generado.
  defp per_type(type, payload, body) when type in ["video", "music"] do
    %{"per_second" => duration_seconds(payload, body) || 0}
  end

  # TTS: el precio de lista es por carácter de ENTRADA (el texto que se
  # sintetiza), que es lo que la request sí trae siempre.
  defp per_type("tts", payload, _body) do
    %{"per_1k_characters" => input_characters(payload)}
  end

  # STT: por minuto (o segundo) de audio transcrito. La duración sale del
  # `usage` del upstream si lo reporta (algunos lo hacen) o de los bytes de
  # audio.
  defp per_type("stt", payload, body) do
    seconds = reported_audio_seconds(body) |> fallback_audio_seconds(input_audio_bytes(payload))

    %{
      "per_second" => seconds,
      "per_minute" => seconds / 60,
      "per_1k_characters" => transcript_characters(body)
    }
  end

  defp per_type(_type, _payload, _body), do: %{}

  ## Tokens ####################################################################

  defp reported_tokens(%{"usage" => %{} = usage}) do
    # `input_tokens` / `output_tokens` es el otro nombre que un upstream usa
    # para los mismos contadores (la API de generación de imágenes los llama
    # así).
    prompt = int(usage["prompt_tokens"]) || int(usage["input_tokens"])
    completion = int(usage["completion_tokens"]) || int(usage["output_tokens"])

    case {prompt, completion} do
      {nil, nil} -> nil
      {p, c} -> (p || 0) + (c || 0)
    end
  end

  defp reported_tokens(_body), do: nil

  defp estimated_tokens(payload) do
    payload
    |> text_fields()
    |> Enum.reduce(0, &(characters(&1) + &2))
  end

  ## Imágenes ##################################################################

  defp image_count(%{"data" => data}) when is_list(data), do: length(data)

  defp image_count(%{"output" => %{"results" => results}}) when is_list(results),
    do: length(results)

  defp image_count(_body), do: nil

  defp request_count(payload) do
    case int(payload["n"]) do
      nil -> 1
      n when n > 0 -> n
      _ -> 1
    end
  end

  # Megapíxeles = área de UNA imagen × cuántas se pidieron. El tamaño viene como
  # "1024x1024"; sin tamaño no hay área y la cantidad es 0 (nunca se inventa).
  defp megapixels(payload, count) do
    case size_dimensions(payload["size"]) do
      {w, h} -> w * h * count / 1_000_000
      nil -> 0
    end
  end

  defp size_dimensions(size) when is_binary(size) do
    case String.split(size, "x", parts: 2) do
      [w, h] ->
        case {int(w), int(h)} do
          {w, h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 -> {w, h}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp size_dimensions(_size), do: nil

  ## Segundos ##################################################################

  defp duration_seconds(payload, body) do
    first_number([
      body["duration"],
      body["seconds"],
      get_in(body, ["usage", "duration"]),
      get_in(body, ["usage", "seconds"]),
      payload["duration"],
      payload["seconds"]
    ])
  end

  ## Caracteres y audio ########################################################

  defp input_characters(payload) do
    payload
    |> text_fields()
    |> Enum.reduce(0, &(characters(&1) + &2))
  end

  defp transcript_characters(%{"text" => text}) when is_binary(text), do: String.length(text)
  defp transcript_characters(_body), do: 0

  defp reported_audio_seconds(body) do
    first_number([
      get_in(body, ["usage", "duration"]),
      get_in(body, ["usage", "seconds"]),
      body["duration"],
      body["seconds"]
    ])
  end

  defp fallback_audio_seconds(nil, bytes), do: audio_seconds_from_bytes(bytes)
  defp fallback_audio_seconds(seconds, _bytes), do: seconds

  @doc """
  Duración aproximada de un audio a partir de sus bytes, a bitrate nominal.

  Es la única estimación del módulo que no sale de la request: se usa cuando el
  upstream no reporta duración Y el cuerpo traído es audio (multipart o data
  URL base64). A 128 kbps, `segundos = bytes × 8 / 128_000`.

      iex> Tokengate.Proxy.ServiceUsage.audio_seconds_from_bytes(160_000)
      10.0

      iex> Tokengate.Proxy.ServiceUsage.audio_seconds_from_bytes(nil)
      0
  """
  @spec audio_seconds_from_bytes(non_neg_integer() | nil) :: float() | integer()
  def audio_seconds_from_bytes(nil), do: 0
  def audio_seconds_from_bytes(0), do: 0

  def audio_seconds_from_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    Float.round(bytes * 8 / @nominal_bits_per_second, 3)
  end

  # Bytes de audio de la request: un data URL base64 (`input_audio.data`) o un
  # `audio_url` http (cuyo tamaño no conocemos desde aquí → nil).
  defp input_audio_bytes(payload) do
    case audio_data(payload) do
      data when is_binary(data) -> base64_bytes(data)
      _ -> nil
    end
  end

  defp audio_data(payload) do
    cond do
      is_map(payload["input_audio"]) -> payload["input_audio"]["data"]
      is_binary(payload["file"]) -> payload["file"]
      is_binary(payload["input_audio"]) -> payload["input_audio"]
      true -> nil
    end
  end

  # "data:audio/mpeg;base64,XXXX" → bytes del payload base64.
  defp base64_bytes(data) do
    case String.split(data, ",", parts: 2) do
      [_header, encoded] -> base64_decoded_size(encoded)
      _ -> base64_decoded_size(data)
    end
  end

  defp base64_decoded_size(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, decoded} -> byte_size(decoded)
      :error -> nil
    end
  end

  ## Helpers ###################################################################

  # Los campos que llevan texto en una request de estos servicios: `input`
  # (tts, y el JSON de stt), `prompt` (image/video/music), `query` (rerank).
  @text_fields ~w(input prompt query)

  defp text_fields(payload) do
    Enum.flat_map(@text_fields, fn field -> List.wrap(payload[field]) end)
  end

  defp characters(value) when is_binary(value), do: String.length(value)
  defp characters(_value), do: 0

  defp first_number(values) do
    Enum.find_value(values, fn value -> number(value) end)
  end

  defp number(value) when is_number(value) and value >= 0, do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp int(value) when is_integer(value) and value >= 0, do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp int(_value), do: nil
end
