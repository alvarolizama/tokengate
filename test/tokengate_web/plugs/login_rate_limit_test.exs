defmodule TokengateWeb.Plugs.LoginRateLimitTest do
  @moduledoc """
  Hallazgo Alto 4 de la auditoría: el rate limit de login tenía UN cubo, llaveado
  por `conn.remote_ip` — que detrás de un proxy es la IP del proxy. Diez intentos
  fallidos contra una cuenta tumbaban el login de toda la instancia.

  Aquí se fijan las tres propiedades que sostienen el fix:

    * el cubo por cuenta aísla: fallar la cuenta A no bloquea a la B;
    * el cubo por cuenta sí bloquea a la A, aunque la contraseña sea correcta;
    * el cubo por IP mide al cliente cuando `TRUST_PROXY_HEADERS` está prendido.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts

  setup do
    reset_counters()
    Application.put_env(:tokengate, :login_rate_limit_max_attempts, 3)
    Application.put_env(:tokengate, :login_rate_limit_max_attempts_per_ip, 50)

    on_exit(fn ->
      Application.delete_env(:tokengate, :login_rate_limit_max_attempts)
      Application.delete_env(:tokengate, :login_rate_limit_max_attempts_per_ip)
      Application.delete_env(:tokengate, :trust_proxy_headers)
      reset_counters()
    end)

    :ok
  end

  defp reset_counters do
    :ets.delete_all_objects(:tokengate_login_rate_limit)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp user_fixture do
    u = System.unique_integer([:positive])
    password = "rate-limit-secret-#{u}1"

    {:ok, user} =
      Accounts.register_user(%{
        email: "rate-#{u}@example.com",
        name: "Rate #{u}",
        password: password
      })

    %{user: user, password: password}
  end

  defp attempt(conn, email, password) do
    post(conn, ~p"/login", %{email: email, password: password})
  end

  test "los fallos de una cuenta no bloquean a otra desde la misma IP" do
    a = user_fixture()
    b = user_fixture()

    for _ <- 1..3 do
      attempt(build_conn(), a.user.email, "contrasena-equivocada-1")
    end

    # Misma IP (127.0.0.1), cuenta distinta: entra.
    ok = attempt(build_conn(), b.user.email, b.password)
    assert redirected_to(ok) == "/dashboard"
  end

  test "el intento siguiente de la cuenta bloqueada no pasa ni con la contraseña correcta" do
    a = user_fixture()

    for _ <- 1..3 do
      attempt(build_conn(), a.user.email, "contrasena-equivocada-1")
    end

    blocked = attempt(build_conn(), a.user.email, a.password)

    assert redirected_to(blocked) == "/login"
    assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "Demasiados intentos"
  end

  test "con TRUST_PROXY_HEADERS el cubo por IP sigue la IP del cliente" do
    # Solo el cubo por IP puede llenarse: el de cuenta queda holgado y cada
    # intento usa una cuenta nueva.
    Application.put_env(:tokengate, :login_rate_limit_max_attempts, 100)
    Application.put_env(:tokengate, :login_rate_limit_max_attempts_per_ip, 3)
    Application.put_env(:tokengate, :trust_proxy_headers, true)

    # Tres intentos desde la MISMA IP de origen, cada uno contra una cuenta
    # distinta: así solo puede llenarse el cubo por IP (el de cuenta queda
    # holgado porque cada email es nuevo).
    for _ <- 1..3 do
      u = user_fixture()

      attempt(
        from_ip(build_conn(), "203.0.113.1"),
        u.user.email,
        "contrasena-equivocada-1"
      )
    end

    # Cuarta cuenta desde esa misma IP: bloqueada por el cubo de IP.
    cuarta = user_fixture()
    blocked = attempt(from_ip(build_conn(), "203.0.113.1"), cuarta.user.email, cuarta.password)
    assert redirected_to(blocked) == "/login"
    assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "Demasiados intentos"

    # Y desde OTRA IP de origen, con credenciales válidas, entra.
    quinta = user_fixture()
    ok = attempt(from_ip(build_conn(), "198.51.100.9"), quinta.user.email, quinta.password)
    assert redirected_to(ok) == "/dashboard"
  end

  test "sin TRUST_PROXY_HEADERS el header no mueve la IP" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.9")

    rewritten = TokengateWeb.Plugs.ClientIp.call(conn, [])
    assert rewritten.remote_ip == conn.remote_ip
  end

  defp from_ip(conn, ip) do
    Plug.Conn.put_req_header(conn, "x-forwarded-for", ip)
  end
end
