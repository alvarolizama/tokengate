defmodule TokengateWeb.SessionRevocationTest do
  @moduledoc """
  Regresión del hallazgo Crítico 1 de la auditoría: suspender a un usuario (o
  rotarle la contraseña) tiene que cortar el acceso REAL, no solo el login.

    * probe 1 — `/dashboard` con la sesión abierta de un usuario suspendido.
    * probe 2 — `/v1/models` con la API key de un usuario suspendido.
    * probe 3 — `/dashboard` con una cookie emitida antes del cambio de contraseña.

  Los tres contestaban 200 antes del fix (evidencia de la auditoría); aquí se
  quedan como candado para que no vuelvan.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts

  defp user_fixture do
    u = System.unique_integer([:positive])
    password = "revocation-secret-#{u}1"

    {:ok, user} =
      Accounts.register_user(%{
        email: "revocation-#{u}@example.com",
        name: "Revocation #{u}",
        password: password
      })

    %{user: user, password: password}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp member_with_key(user) do
    u = System.unique_integer([:positive])

    {:ok, group} =
      Accounts.create_group(%{
        "name" => "Revocation Group #{u}",
        "default_rpm_limit" => 120,
        "default_concurrency_limit" => 10
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    {member, token}
  end

  # Cookie armada a mano para probar el tope absoluto sin esperar 30 días.
  defp session_conn(user, started_at) do
    build_conn()
    |> init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version || 0)
    |> put_session(:session_started_at, started_at)
  end

  describe "suspensión" do
    test "probe 1: la sesión de dashboard de un usuario suspendido ya no entra", %{conn: conn} do
      %{user: user, password: password} = user_fixture()
      conn = login(conn, user, password)

      # La sesión recién abierta entra.
      assert get(conn, ~p"/dashboard").status == 200

      {:ok, _suspended} = Accounts.admin_update_user(user, %{"status" => "suspended"})

      # Y deja de entrar en el siguiente request, sin volver a hacer login.
      bounced = get(conn, ~p"/dashboard")
      assert bounced.status == 302
      assert redirected_to(bounced) == "/login"
    end

    test "probe 2: la API key de un usuario suspendido recibe 401", %{conn: conn} do
      %{user: user} = user_fixture()
      {_member, token} = member_with_key(user)

      ok =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/v1/models")

      assert ok.status == 200

      {:ok, _suspended} = Accounts.admin_update_user(user, %{"status" => "suspended"})

      rejected =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/v1/models")

      assert rejected.status == 401
      assert %{"error" => %{"code" => "invalid_api_key"}} = Jason.decode!(rejected.resp_body)
    end
  end

  describe "rotación de contraseña" do
    test "probe 3: la cookie emitida antes del cambio ya no entra", %{conn: conn} do
      %{user: user, password: password} = user_fixture()
      conn = login(conn, user, password)

      assert get(conn, ~p"/dashboard").status == 200

      # Cambio de contraseña propio (re-autenticando con la actual).
      {:ok, _user} =
        Accounts.update_user_password(user, %{
          "current_password" => password,
          "password" => "otra-clave-nueva-1"
        })

      # La cookie vieja — la que tenía el atacante o la que quedó en el navegador
      # antes del cambio — deja de servir.
      bounced = get(conn, ~p"/dashboard")
      assert bounced.status == 302
      assert redirected_to(bounced) == "/login"
    end

    test "el cambio de contraseña no tumba la sesión de OTRO usuario", %{conn: conn} do
      %{user: user, password: password} = user_fixture()
      %{user: otro, password: otra_password} = user_fixture()

      _conn = login(conn, user, password)
      other_conn = login(build_conn(), otro, otra_password)

      {:ok, _} =
        Accounts.update_user_password(user, %{
          "current_password" => password,
          "password" => "otra-clave-nueva-1"
        })

      assert get(other_conn, ~p"/dashboard").status == 200
    end
  end

  describe "tope absoluto de vida" do
    # La cookie se renueva en cada request (`renew: true`), así que `max_age` solo
    # mide inactividad: sin este techo, una sesión que se usa todos los días no
    # expira nunca y una cookie robada vale para siempre.
    test "probe 4: una cookie más vieja que el tope rebota a /login" do
      %{user: user} = user_fixture()
      too_old = System.system_time(:second) - 31 * 24 * 3600

      bounced = get(session_conn(user, too_old), ~p"/dashboard")

      assert bounced.status == 302
      assert redirected_to(bounced) == "/login"
    end

    test "probe 4b: dentro del tope, la misma cookie entra" do
      %{user: user} = user_fixture()
      fresh = System.system_time(:second) - 3600

      assert get(session_conn(user, fresh), ~p"/dashboard").status == 200
    end
  end
end
