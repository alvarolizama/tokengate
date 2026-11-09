defmodule TokengateWeb.FaviconTest do
  @moduledoc """
  El favicon tiene que estar **servido**, no solo presente en disco: `Plug.Static`
  sirve únicamente lo que lista `static_paths/0`, y ese es el tipo de detalle que
  se rompe en silencio (el archivo queda en `priv/static`, la pestaña muestra el
  hueco y nadie lo nota hasta que un usuario lo reporta).

  Cubre las dos formas que referencia `root.html.heex` (SVG para navegadores
  modernos, ICO como alternativo) y que el layout las enlace.
  """

  use TokengateWeb.ConnCase, async: true

  test "el favicon SVG se sirve con su tipo", %{conn: conn} do
    conn = get(conn, "/favicon.svg")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/svg+xml"
    assert conn.resp_body =~ "<svg"
  end

  test "el favicon ICO se sirve", %{conn: conn} do
    conn = get(conn, "/favicon.ico")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image"
  end

  test "el layout raíz enlaza los dos iconos", %{conn: conn} do
    # Con cero usuarios `/login` manda al onboarding del primer arranque; se
    # registra uno para poder renderizar el formulario y su `<head>`.
    u = System.unique_integer([:positive])

    {:ok, _user} =
      Tokengate.Accounts.register_user(%{
        "email" => "favicon-#{u}@example.com",
        "name" => "Favicon #{u}",
        "password" => "favicon-secret-#{u}1"
      })

    html = conn |> get(~p"/login") |> html_response(200)

    assert html =~ ~s(rel="icon")
    assert html =~ "/favicon.svg"
    assert html =~ "/favicon.ico"
  end
end
