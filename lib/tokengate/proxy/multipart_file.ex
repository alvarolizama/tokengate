defmodule Tokengate.Proxy.MultipartFile do
  @moduledoc """
  Los BYTES de una parte de archivo de un cuerpo `multipart/form-data` crudo.

  El proxy reenvía el cuerpo multipart byte-for-byte (ver
  `TokengateWeb.Plugs.MediaBodyParser`), y `payload["file"]` llega como
  `Tokengate.Proxy.MediaFile`: metadatos, sin bytes, porque los bytes viven una
  sola vez en el cuerpo capturado. Un dialecto que NO puede reenviar el
  multipart —porque su upstream quiere el audio en un JSON, como el Token Plan
  de Alibaba— necesita sacarlos de ahí.

  Se reusa el parser de bajo nivel de Plug (`:plug_multipart`) que ya usa el
  plug, en vez de partir el cuerpo con expresiones regulares: el mismo
  entendimiento de boundaries, headers y partes.

  Sólo se extrae la PRIMERA parte de archivo: los endpoints de transcripción
  aceptan un único audio, y devolver todos los archivos de un cuerpo con varios
  invitaría a mandar el equivocado al upstream.
  """

  @doc """
  Extrae la primera parte de archivo de un cuerpo multipart.

  Devuelve `{:ok, %{bytes:, filename:, content_type:}}` o `:error` cuando el
  cuerpo no es multipart, no trae ninguna parte de archivo, o no se pudo
  parsear (truncado, boundary ausente).

      iex> Tokengate.Proxy.MultipartFile.extract("no-es-multipart", "application/json")
      :error

      iex> Tokengate.Proxy.MultipartFile.extract(nil, nil)
      :error
  """
  @spec extract(binary() | nil, String.t() | nil) ::
          {:ok, %{bytes: binary(), filename: String.t() | nil, content_type: String.t() | nil}}
          | :error
  def extract(raw_body, content_type)
      when is_binary(raw_body) and is_binary(content_type) do
    with {:ok, boundary} <- boundary(content_type) do
      collect(raw_body, boundary)
    end
  end

  def extract(_raw_body, _content_type), do: :error

  ## Internals #################################################################

  # `multipart/form-data; boundary=...` — Plug's own header parser gives the
  # params already unquoted.
  defp boundary(content_type) do
    case Plug.Conn.Utils.media_type(content_type) do
      {:ok, "multipart", _subtype, %{"boundary" => boundary}} when boundary != "" ->
        {:ok, boundary}

      _ ->
        :error
    end
  end

  defp collect(body, boundary) do
    case :plug_multipart.parse_headers(body, boundary) do
      {:ok, headers, rest} ->
        {bytes, rest} = part_body(rest, boundary)

        case :plug_multipart.form_data(headers) do
          {_kind, _name, filename, part_content_type, _encoding} ->
            {:ok,
             %{
               bytes: bytes,
               filename: filename,
               content_type: part_content_type
             }}

          {_kind, _name} ->
            # A form field (not a file): keep walking for the file part.
            collect(rest, boundary)
        end

      _ ->
        # `{:done, epilogue}` — end of the body — or a truncated one.
        :error
    end
  end

  defp part_body(rest, boundary) do
    case :plug_multipart.parse_body(rest, boundary) do
      {:ok, value} -> {value, ""}
      {:ok, value, rest} -> {value, rest}
      {:done, value} -> {value, ""}
      {:done, value, rest} -> {value, rest}
    end
  end
end
