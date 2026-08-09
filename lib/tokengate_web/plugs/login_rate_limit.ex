defmodule TokengateWeb.Plugs.LoginRateLimit do
  @moduledoc """
  ETS-backed fixed-window rate limiter for the login endpoint.

  Throttles `POST /login` attempts per client IP: after `@max_attempts`
  failed-or-total attempts within `@window_ms`, the plug short-circuits with
  a 429 (rendered as the login form with an error flash) until the window
  resets. Successful logins clear the counter for that IP.

  The table is owned by the endpoint process via `Plug.Session`-style
  persistence: we lazily create a named public table on first use (the
  creating process is the caller, so we hand ownership to a `:heir` —
  the endpoint — is overkill). Instead the table is created with
  `read_concurrency`/`write_concurrency` from whichever request process
  first arrives, and kept alive by registering it under
  `Tokengate.LoginRateLimit.TableKeeper`, a tiny GenServer started in the
  application supervisor that takes ownership via `:ets.give_away`.

  Simpler: the table is created by the keeper GenServer itself when the
  plug calls `ensure_table/0` — the keeper holds it for the app's lifetime.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  require Logger

  alias TokengateWeb.Plugs.LoginRateLimit.TableKeeper

  @max_attempts 10
  @window_ms 60_000

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    key = client_key(conn)

    case TableKeeper.hit(key, window_ms(), max_attempts()) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_s} ->
        Logger.warning("login_rate_limited ip=#{key}")

        conn
        |> put_flash(
          :error,
          "Demasiados intentos. Espera #{retry_after_s} segundos e intenta de nuevo."
        )
        |> redirect(to: "/login")
        |> halt()
    end
  end

  @doc "Clears the attempt counter for the IP after a successful login."
  def clear(conn), do: TableKeeper.clear(client_key(conn))

  defp client_key(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  # Test overrides via env config; defaults are compile-time sane values.
  defp window_ms, do: Application.get_env(:tokengate, :login_rate_limit_window_ms, @window_ms)

  defp max_attempts,
    do: Application.get_env(:tokengate, :login_rate_limit_max_attempts, @max_attempts)

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
