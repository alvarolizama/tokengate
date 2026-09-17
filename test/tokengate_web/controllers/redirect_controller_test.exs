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

    test "/dashboard/services/supervised → /services/supervised", %{conn: conn} do
      conn = get(conn, "/dashboard/services/supervised")
      assert redirected_to(conn) == "/services/supervised"
    end

    test "/dashboard/services/supervised?period=30d → /services/supervised?period=30d", %{
      conn: conn
    } do
      conn = get(conn, "/dashboard/services/supervised?period=30d")
      assert redirected_to(conn) == "/services/supervised?period=30d"
    end
  end

  # La sección «Crédito» pasó a «Presupuesto» y sus rutas a /budget/*: los
  # presupuestos mensuales (antes /access/groups) y los top-ups (antes
  # /credit/topups). Los bookmarks viejos no quedan en 404.
  describe "sección Presupuesto (/budget/*)" do
    test "/access/groups → /budget/months", %{conn: conn} do
      conn = get(conn, "/access/groups")
      assert redirected_to(conn) == "/budget/months"
    end

    test "/access/groups/:id/members → /budget/months/:id/members", %{conn: conn} do
      conn = get(conn, "/access/groups/42/members")
      assert redirected_to(conn) == "/budget/months/42/members"
    end

    test "/access/groups/:id/members?period=7d → subruta y query preservadas", %{conn: conn} do
      conn = get(conn, "/access/groups/42/members?period=7d")
      assert redirected_to(conn) == "/budget/months/42/members?period=7d"
    end

    test "/credit/topups → /budget/topups", %{conn: conn} do
      conn = get(conn, "/credit/topups")
      assert redirected_to(conn) == "/budget/topups"
    end

    test "/credit/topups?archived=true → query preservada", %{conn: conn} do
      conn = get(conn, "/credit/topups?archived=true")
      assert redirected_to(conn) == "/budget/topups?archived=true"
    end

    test "/credit/subscriptions → /budget/topups", %{conn: conn} do
      conn = get(conn, "/credit/subscriptions")
      assert redirected_to(conn) == "/budget/topups"
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
