defmodule TokengateWeb.CreditsRedirectTest do
  @moduledoc """
  El tab Créditos se disolvió en cada dimensión del hub /stats: barra org
  en En vivo/Resumen, columnas de presupuesto en Usuarios/Grupos/Servicios
  y barra de grupo en el hub. Estos tests cubren los redirects de los
  bookmarks antiguos.
  """

  use TokengateWeb.ConnCase, async: true

  test "/stats/credits redirects to /stats/overview", %{conn: conn} do
    conn = get(conn, "/stats/credits")
    assert redirected_to(conn) == "/stats/overview"
  end

  test "/dashboard/credits redirects to /stats/overview", %{conn: conn} do
    conn = get(conn, "/dashboard/credits")
    assert redirected_to(conn) == "/stats/overview"
  end

  test "/stats/credits deep paths redirect too", %{conn: conn} do
    conn = get(conn, "/stats/credits/some/sub")
    assert redirected_to(conn) == "/stats/overview"
  end

  # Las suscripciones desaparecieron con el modelo de límite mensual +
  # top-ups: la página se elimina, pero los bookmarks viejos no quedan en 404.
  test "/credit/subscriptions redirects to /credit/topups", %{conn: conn} do
    conn = get(conn, "/credit/subscriptions")
    assert redirected_to(conn) == "/credit/topups"
  end

  test "/credit/subscriptions deep paths redirect too", %{conn: conn} do
    conn = get(conn, "/credit/subscriptions/whatever")
    assert redirected_to(conn) == "/credit/topups"
  end
end
