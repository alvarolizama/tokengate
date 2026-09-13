defmodule TokengateWeb.RedirectController do
  @moduledoc """
  Permanent redirects for moved dashboard pages.
  """

  use TokengateWeb, :controller

  @doc "``/dashboard/credits`` → ``/stats/credits``"
  def stats_credits(conn, _params) do
    redirect(conn, to: ~p"/stats/credits")
  end

  @doc """
  ``/dashboard/stats[...rest]`` → ``/stats[...rest]``.

  Preserva subruta (`/models`, `/groups`, …) y query string.
  """
  def stats(conn, params) do
    rest =
      params
      |> Map.get("rest", [])
      |> List.wrap()
      |> Enum.join("/")

    to =
      if rest == "" do
        ~p"/stats"
      else
        "/stats/#{rest}"
      end
      |> append_query(conn)

    redirect(conn, to: to)
  end

  @doc "``/dashboard/calculator`` → ``/calculator``"
  def calculator(conn, _params) do
    redirect(conn, to: append_query(~p"/calculator", conn))
  end

  @doc "``/admin/logs`` → ``/logs``"
  def logs(conn, _params) do
    redirect(conn, to: append_query(~p"/logs", conn))
  end

  defp append_query(path, conn) do
    case conn.query_string do
      "" -> path
      qs -> "#{path}?#{qs}"
    end
  end
end
