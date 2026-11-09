defmodule TokengateWeb.Plugs.LoginRateLimit do
  @moduledoc """
  ETS-backed fixed-window rate limiter for the login endpoint.

  Throttles `POST /login` on **two independent buckets**:

    * **per account** — `max_attempts/0` attempts per window for the same email
      (trimmed + downcased). This is the bucket that protects a specific account
      from brute force, and the one that keeps working when the deployment does
      not rewrite the client IP.
    * **per IP** — `max_attempts_per_ip/0` attempts per window from the same
      source. Deliberately wide: a batch of failures against account A must not
      lock account B out for everyone behind the same address.

  Antes había un solo cubo, llaveado por `conn.remote_ip`. Detrás de un proxy
  esa IP es la del proxy, así que el cubo era **global**: diez intentos fallidos
  tumbaban el login de toda la instancia (hallazgo Alto 4 de la auditoría
  2026-11-08). El bucket por cuenta es lo que sostiene la protección aunque
  `TRUST_PROXY_HEADERS` esté apagado; `TokengateWeb.Plugs.ClientIp` es lo que
  hace que el bucket por IP mida al cliente y no al proxy.

  Un login exitoso limpia los dos contadores (`clear/1`), como antes: la ventana
  cuenta intentos *acumulados*, no fallos, porque el plug corre antes que el
  controller y no conoce el desenlace.

  The ETS table is owned by `TokengateWeb.Plugs.LoginRateLimit.TableKeeper`,
  a tiny GenServer started in the application supervisor. The keeper creates
  the table at init and holds it for the app's lifetime — individual request
  processes never create or own the table.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  require Logger
  alias TokengateWeb.Plugs.LoginRateLimit.TableKeeper

  @max_attempts 10
  @max_attempts_per_ip 50
  @window_ms 60_000

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    account = account_key(conn)
    ip = ip_key(conn)

    with {:allow, _} <- hit(account, max_attempts()),
         {:allow, _} <- hit(ip, max_attempts_per_ip()) do
      conn
    else
      {:deny, retry_after_s} ->
        Logger.warning("login_rate_limited account=#{inspect(account)} ip=#{inspect(ip)}")

        conn
        |> put_flash(
          :error,
          "Demasiados intentos. Espera #{retry_after_s} segundos e intenta de nuevo."
        )
        |> redirect(to: "/login")
        |> halt()
    end
  end

  @doc "Clears both counters (account and IP) after a successful login."
  def clear(conn) do
    TableKeeper.clear(account_key(conn))
    TableKeeper.clear(ip_key(conn))
  end

  # Sin email en el body (form incompleto, body que no parseó) no hay cubo por
  # cuenta: solo cuenta el de IP. Nunca se inventa una llave vacía compartida
  # por todos.
  defp account_key(conn) do
    case conn.body_params do
      %{"email" => email} when is_binary(email) ->
        case email |> String.trim() |> String.downcase() do
          "" -> nil
          normalized -> {:account, normalized}
        end

      _ ->
        nil
    end
  end

  defp ip_key(conn) do
    {:ip, conn.remote_ip |> :inet.ntoa() |> to_string()}
  end

  defp hit(nil, _max), do: {:allow, 0}
  defp hit(key, max), do: TableKeeper.hit(key, window_ms(), max)

  # Test overrides via env config; defaults are compile-time sane values.
  defp window_ms, do: Application.get_env(:tokengate, :login_rate_limit_window_ms, @window_ms)

  defp max_attempts,
    do: Application.get_env(:tokengate, :login_rate_limit_max_attempts, @max_attempts)

  defp max_attempts_per_ip,
    do:
      Application.get_env(:tokengate, :login_rate_limit_max_attempts_per_ip, @max_attempts_per_ip)

  defmodule TableKeeper do
    @moduledoc """
    Owns the ETS table backing `LoginRateLimit`. Started under the
    application supervisor so the table survives individual request
    processes. Counters live in the caller's process (no GenServer
    bottleneck on the hot path); the keeper only owns the table and runs
    a periodic sweep of expired windows so idle IPs don't accumulate.
    """

    use GenServer

    @table :tokengate_login_rate_limit
    @sweep_ms 60_000

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc """
    Records one attempt for `key`. Returns `{:allow, count}` while under
    the limit, `{:deny, retry_after_seconds}` once exceeded.
    """
    def hit(key, window_ms, max_attempts) do
      ensure_table()
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{^key, count, window_start}] when now - window_start < window_ms ->
          if count >= max_attempts do
            retry_after = div(window_ms - (now - window_start), 1000) + 1
            {:deny, retry_after}
          else
            :ets.update_counter(@table, key, {2, 1}, {key, 0, now})
            {:allow, count + 1}
          end

        _ ->
          :ets.insert(@table, {key, 1, now})
          {:allow, 1}
      end
    end

    @doc "Resets the counter for `key` (called after a successful login)."
    def clear(nil), do: :ok

    def clear(key) do
      ensure_table()
      :ets.delete(@table, key)
      :ok
    end

    @impl true
    def init(_opts) do
      ensure_table()
      Process.send_after(self(), :sweep, @sweep_ms)
      {:ok, %{}}
    end

    @impl true
    def handle_info(:sweep, state) do
      window_ms = Application.get_env(:tokengate, :login_rate_limit_window_ms, 60_000)
      cutoff = System.monotonic_time(:millisecond) - window_ms

      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

      Process.send_after(self(), :sweep, @sweep_ms)
      {:noreply, state}
    end

    defp ensure_table do
      case :ets.whereis(@table) do
        :undefined ->
          # Race is benign: two creators, one wins via :named_table error.
          try do
            :ets.new(@table, [
              :named_table,
              :public,
              :set,
              read_concurrency: true,
              write_concurrency: true
            ])
          rescue
            ArgumentError -> @table
          end

        tid ->
          tid
      end
    end
  end
end
