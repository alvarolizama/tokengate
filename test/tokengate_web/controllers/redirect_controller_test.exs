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

  # El vocabulario «perfil de límites» reemplazó a «perfiles de límites» / «presupuestos
  # mensuales»: la página vive en /budget/profiles y las dos generaciones
  # anteriores de la URL caen ahí con un redirect que preserva subruta y
  # query string (bookmarks viejos no quedan en 404).
  describe "sección Presupuesto (/budget/*)" do
    test "/access/groups → /budget/profiles", %{conn: conn} do
      conn = get(conn, "/access/groups")
      assert redirected_to(conn) == "/budget/profiles"
    end

    test "/access/groups/:id/members → /budget/profiles/:id/members (subruta preservada)", %{
      conn: conn
    } do
      conn = get(conn, "/access/groups/42/members")
      assert redirected_to(conn) == "/budget/profiles/42/members"
    end

    test "/access/groups/:id/members?period=7d → subruta y query preservadas", %{conn: conn} do
      conn = get(conn, "/access/groups/42/members?period=7d")
      assert redirected_to(conn) == "/budget/profiles/42/members?period=7d"
    end

    test "/budget/months → /budget/profiles", %{conn: conn} do
      conn = get(conn, "/budget/months")
      assert redirected_to(conn) == "/budget/profiles"
    end

    test "/budget/months/:id/members → /budget/profiles/:id/members", %{conn: conn} do
      conn = get(conn, "/budget/months/42/members")
      assert redirected_to(conn) == "/budget/profiles/42/members"
    end

    test "/budget/months/:id/members?page=2&q=x → subruta y query preservadas", %{conn: conn} do
      conn = get(conn, "/budget/months/42/members?page=2&q=x")
      assert redirected_to(conn) == "/budget/profiles/42/members?page=2&q=x"
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

  # El hub de stats llamaba «perfiles de límites» al sujeto del techo mensual; ahora es
  # «perfil de límites» (/stats/profiles).
  describe "hub de stats (/stats/profiles)" do
    test "/stats/groups → /stats/profiles", %{conn: conn} do
      conn = get(conn, "/stats/groups")
      assert redirected_to(conn) == "/stats/profiles"
    end

    test "/stats/groups/:group_id → /stats/profiles/:group_id (subruta preservada)", %{conn: conn} do
      conn = get(conn, "/stats/groups/42")
      assert redirected_to(conn) == "/stats/profiles/42"
    end

    test "/stats/groups/:group_id?period=today → subruta y query preservadas", %{conn: conn} do
      conn = get(conn, "/stats/groups/42?period=today&group_id=42")
      assert redirected_to(conn) == "/stats/profiles/42?period=today&group_id=42"
    end
  end

  # Los redirects de este controller usan `redirect/2` (302), la misma
  # convención que el resto de las páginas movidas. Está fijado aquí para que
  # un cambio de status sea deliberado y visible.
  describe "status de los redirects" do
    test "un bookmark viejo responde 302 con Location al destino nuevo", %{conn: conn} do
      conn = get(conn, "/budget/months")
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/budget/profiles"]
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
