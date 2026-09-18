defmodule TokengateWeb.HealthControllerTest do
  @moduledoc """
  The liveness probe contract: 200, no session, no database.

  The "no DB" half is structural (the action calls no Repo at all — see the
  controller's moduledoc); what this pins is the wire contract the proxy reads:
  a bare 200 on a route that does NOT live in the :browser pipeline, so a proxy
  configured for "200" never sees the `/` → `/login` redirect it would read as
  down.
  """

  use TokengateWeb.ConnCase

  test "GET /health answers 200 without a session", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    assert response(conn, 200) == ~s({"status":"ok"})
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /health does not require a logged-in user", %{conn: conn} do
    # No login, no session cookie: it must still be 200 (not a redirect to
    # /login like `/`).
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    refute get_resp_header(conn, "set-cookie") |> Enum.any?(&String.contains?(&1, "session"))
  end
end
