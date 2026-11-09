defmodule TokengateWeb.Plugs.ClientIp do
  @moduledoc """
  Reescribe `conn.remote_ip` con la IP real del cliente cuando la instancia vive
  detrás de un reverse proxy (`TRUST_PROXY_HEADERS=true`).

  Sin esto, `conn.remote_ip` es **siempre** la del proxy: todo lo que se llavea
  por IP (el rate limit de login, el `ip` del audit log) mide al proxy, no al
  cliente. Ese fue el hallazgo Alto 4 de la auditoría 2026-11-08: con un solo
  cubo, diez intentos fallidos tumbaban el login de toda la instancia.

  ## De qué hop se toma la IP

  Del **último** elemento de `X-Forwarded-For`, no del primero. El proxy que
  tenemos delante (Traefik) *agrega* la IP del cliente al final de la lista que
  el cliente ya había mandado, así que el primer elemento es texto que el
  atacante escribió y el último es el que vio el proxy. Tomar el primero —lo que
  hace `Plug.RewriteOn, [:x_forwarded_for]`— entrega la IP al cliente.

  ## Por qué apagado por default

  Confiar en el header sin proxy delante es exactamente lo que hace falsificable
  el `ip` del audit log: el cliente se inventa la IP que quiera. Se prende en
  `runtime.exs` con `TRUST_PROXY_HEADERS=true`, y solo cuando hay un proxy que
  reescribe el header en el path.
  """

  import Plug.Conn

  @behaviour Plug

  @truthy [true, "true", "1", 1]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with true <- trust_proxy?(),
         [forwarded | _] <- get_req_header(conn, "x-forwarded-for"),
         {:ok, ip} <- last_hop(forwarded) do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  @doc "¿La instancia declara que vive detrás de un proxy de confianza?"
  def trust_proxy? do
    Application.get_env(:tokengate, :trust_proxy_headers, false) in @truthy
  end

  defp last_hop(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> :error
      candidate -> :inet.parse_address(String.to_charlist(candidate))
    end
  end
end
