defmodule TokengateWeb.Plugs.ProxyPreAuth do
  @moduledoc """
  Guard barato del proxy: corta un request **sin credencial** antes de que se
  lea el body.

  `MediaBodyParser` corre en el endpoint, antes del router, y captura hasta
  10 MB del cuerpo en memoria; con el `read_length` actual eso ocurre para
  cualquier método con cuerpo bajo `/v1`, tenga o no credencial. Sin este plug,
  cualquiera en Internet puede empujar cuerpos de 10 MB sin presentar token, y
  cada token inválido además dispara una query a Postgres (el cache de auth no
  cachea los fallos a propósito).

  Con el guard, el 401 sale **antes** de `read_body/2` y antes de cualquier
  query.

  ## Contrato con `ApiAuth`

  Responde exactamente lo mismo que respondería `ApiAuth` — mismos códigos y
  mismo shape OpenAI — para que un cliente legítimo no note diferencia alguna:
  un token que este plug deja pasar es uno que `ApiAuth` iba a rechazar igual
  como `invalid_api_key`. El formato aceptado es el que emite
  `Tokengate.Accounts.generate_api_key_material/0` (`tg-` + base64url de 24
  bytes); nada más.
  """

  import Plug.Conn

  @behaviour Plug

  # "tg-" + Base.url_encode64(24 bytes, padding: false) = 35 chars. El piso de 20
  # deja aire sin abrir la puerta a tokens que el gateway jamás emitió.
  @token_format ~r/^tg-[A-Za-z0-9_-]{20,}$/

  @impl true
  def init(opts), do: Keyword.get(opts, :prefixes, ["/v1/"])

  @impl true
  def call(conn, prefixes) do
    if prefixed?(conn, prefixes), do: guard(conn), else: conn
  end

  defp prefixed?(conn, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(conn.request_path, &1))
  end

  defp guard(conn) do
    case bearer(conn) do
      :missing -> reject(conn, 401, "missing_api_key", "Missing bearer token")
      :malformed -> reject(conn, 401, "invalid_api_key", "Invalid API key")
      {:ok, _token} -> conn
    end
  end

  # Mismo parseo que `ApiAuth.bearer_token/1`: `Bearer ` literal y token no
  # vacío. El scheme en minúsculas o un header sin `Bearer` cae en :missing,
  # igual que allá.
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 ->
        if Regex.match?(@token_format, token), do: {:ok, token}, else: :malformed

      _ ->
        :missing
    end
  end

  defp reject(conn, status, code, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => "authentication_error",
        "code" => code
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
