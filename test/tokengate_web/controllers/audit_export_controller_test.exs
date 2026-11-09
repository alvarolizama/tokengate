defmodule TokengateWeb.AuditExportControllerTest do
  @moduledoc """
  El CSV de auditoría es el único export que trae campos controlados por el
  cliente (`user_agent`, `origin`, `target_label`) sin ninguna validación de
  contenido. Antes del fix solo citaba comas y comillas: una celda que empieza
  con `=` se evalúa como fórmula al abrir el archivo en Excel/Sheets (hallazgo
  Medio 6 de la auditoría 2026-11-08).
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Auditing

  defp admin_fixture do
    u = System.unique_integer([:positive])
    password = "audit-export-secret-#{u}1"

    {:ok, admin} =
      Accounts.admin_create_user(%{
        email: "audit-export-#{u}@example.com",
        name: "Audit Export #{u}",
        password: password,
        global_role: "admin",
        status: "active"
      })

    %{admin: admin, password: password}
  end

  defp user_fixture do
    u = System.unique_integer([:positive])
    password = "audit-plain-secret-#{u}1"

    {:ok, user} =
      Accounts.register_user(%{
        email: "audit-plain-#{u}@example.com",
        name: "Audit Plain #{u}",
        password: password
      })

    %{user: user, password: password}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  test "las fórmulas en campos del cliente salen neutralizadas", %{conn: conn} do
    %{admin: admin, password: password} = admin_fixture()

    {:ok, _} =
      Auditing.log(admin, "probe.csv_formula", "user", admin.id, %{}, %{
        user_agent: "=cmd|' /C calc'!A0",
        origin: "web"
      })

    csv =
      conn
      |> login(admin, password)
      |> get(~p"/operations/audit/export")
      |> Map.fetch!(:resp_body)

    # El apóstrofo va delante del `=`: el spreadsheet lo lee como texto.
    assert csv =~ "'=cmd|"

    # Y ninguna celda arranca con `=` (ni al inicio del archivo ni tras un salto).
    refute csv =~ "\n=cmd"
  end

  test "el CSV de auditoría también cita comas y comillas", %{conn: conn} do
    %{admin: admin, password: password} = admin_fixture()

    {:ok, _} =
      Auditing.log(admin, "probe.csv_quotes", "user", admin.id, %{}, %{
        user_agent: ~s(Mozilla/5.0, "weird" agent),
        origin: "web"
      })

    csv =
      conn
      |> login(admin, password)
      |> get(~p"/operations/audit/export")
      |> Map.fetch!(:resp_body)

    assert csv =~ ~s("Mozilla/5.0, ""weird"" agent")
  end

  test "un usuario sin rol admin no baja el CSV", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn =
      conn
      |> login(user, password)
      |> get(~p"/operations/audit/export")

    assert redirected_to(conn) == "/dashboard"
  end
end
