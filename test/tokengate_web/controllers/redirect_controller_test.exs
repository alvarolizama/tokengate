defmodule TokengateWeb.RedirectControllerTest do
  use TokengateWeb.ConnCase, async: true

  describe "legacy URL redirects" do
    test "/dashboard/stats → /stats", %{conn: conn} do
      conn = get(conn, "/dashboard/stats")
      assert redirected_to(conn) == "/stats"
    end

    test "/dashboard/stats/models?period=7d → /stats/models?period=7d", %{conn: conn} do
      conn = get(conn, "/dashboard/stats/models?period=7d")
      assert redirected_to(conn) == "/stats/models?period=7d"
    end

    test "/dashboard/stats/members/42 → /stats/members/42", %{conn: conn} do
      conn = get(conn, "/dashboard/stats/members/42")
      assert redirected_to(conn) == "/stats/members/42"
    end

    test "/dashboard/calculator → /calculator", %{conn: conn} do
      conn = get(conn, "/dashboard/calculator")
      assert redirected_to(conn) == "/calculator"
    end

    test "/logs → /operations/monitoring (query string preservado)", %{conn: conn} do
      conn = get(conn, "/logs?period=7d&status_class=5xx")
      assert redirected_to(conn) == "/operations/monitoring?period=7d&status_class=5xx"
    end

    test "/dashboard/credits → /stats/overview (tab Créditos disuelto)", %{conn: conn} do
      conn = get(conn, "/dashboard/credits")
      assert redirected_to(conn) == "/stats/overview"
    end
  end

  # El prefijo /admin se partió en las sub-secciones del sidebar
  # (/catalog, /access, /credit, /operations). Se decidió NO dejar
  # redirects: estas URLs responden 404 a propósito, no es un olvido.
  describe "/admin* retirado sin redirects legacy" do
    test "/admin/providers → 404", %{conn: conn} do
      assert get(conn, "/admin/providers").status == 404
    end

    test "/admin/models → 404", %{conn: conn} do
      assert get(conn, "/admin/models").status == 404
    end

    test "/admin/groups/:id/members → 404", %{conn: conn} do
      assert get(conn, "/admin/groups/1/members").status == 404
    end

    test "/admin/users → 404", %{conn: conn} do
      assert get(conn, "/admin/users").status == 404
    end

    test "/admin/logs (el redirect legacy se fue con el prefijo) → 404", %{conn: conn} do
      assert get(conn, "/admin/logs").status == 404
    end

    test "/admin/users/:user_id/stats (redirect legacy eliminado) → 404", %{conn: conn} do
      assert get(conn, "/admin/users/1/stats").status == 404
    end

    test "/admin a secas → 404", %{conn: conn} do
      assert get(conn, "/admin").status == 404
    end
  end
end
