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

    test "/admin/logs → /logs", %{conn: conn} do
      conn = get(conn, "/admin/logs")
      assert redirected_to(conn) == "/logs"
    end

    test "/dashboard/credits → /stats/overview (tab Créditos disuelto)", %{conn: conn} do
      conn = get(conn, "/dashboard/credits")
      assert redirected_to(conn) == "/stats/overview"
    end
  end
end
