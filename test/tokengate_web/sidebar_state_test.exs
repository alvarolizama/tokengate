defmodule TokengateWeb.SidebarStateTest do
  @moduledoc """
  El estado del rail del sidebar vive en la clase `sidebar-collapsed` de
  `<html>`, aplicada por el root layout desde la cookie `tokengate_sidebar`
  ANTES del primer paint. No puede vivir en un nodo que LiveView renderice:
  morphdom resincroniza los atributos desde el HTML del servidor en cada patch
  y el rail se reabría solo con los timers de dashboard/stats/monitoring.
  """

  use TokengateWeb.ConnCase, async: true

  test "la cookie tokengate_sidebar=collapsed colapsa el rail en el primer paint" do
    conn =
      build_conn()
      |> put_req_cookie("tokengate_sidebar", "collapsed")
      |> get(~p"/onboarding")

    assert html_response(conn, 200) =~ "sidebar-collapsed"
  end

  test "sin la cookie el sidebar queda expandido (sin la clase)" do
    conn = get(build_conn(), ~p"/onboarding")

    refute html_response(conn, 200) =~ "sidebar-collapsed"
  end

  test "la cookie en otro valor distinto de collapsed no colapsa" do
    conn =
      build_conn()
      |> put_req_cookie("tokengate_sidebar", "expanded")
      |> get(~p"/onboarding")

    refute html_response(conn, 200) =~ "sidebar-collapsed"
  end
end
