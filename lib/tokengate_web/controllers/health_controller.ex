defmodule TokengateWeb.HealthController do
  @moduledoc """
  Liveness probe for the container/proxy.

  Answers `200` as soon as the Endpoint is listening and touches NOTHING else: no
  session, no cookie, no database. That is the point — the probe runs while the
  app is still warming up, which is exactly when the connection pool is busiest
  (the boot tasks seed the catalog and ensure partitions), so a probe that
  queried the DB could itself time out and mark a healthy container as down.

  Use this path (`/health`) as the healthcheck target, NOT `/`: `/` redirects to
  `/login` (302), and a proxy configured to expect `200` reads that as "unhealthy"
  and returns 502 Bad Gateway for a container that is serving fine.
  """

  use TokengateWeb, :controller

  @body ~s({"status":"ok"})

  @doc "GET /health — always 200 while the Endpoint is up."
  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, @body)
  end
end
