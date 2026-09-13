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

  @doc """
  ``/stats/members/:member_id`` → ``/stats/users/:user_id``.

  El detalle por membresía fue reemplazado por el detalle consolidado
  por usuario (agrega todas sus membresías). Resuelve el usuario desde
  la membresía.
  """
  def stats_member(conn, %{"member_id" => member_id}) do
    case Tokengate.Accounts.get_group_member(member_id) do
      %{user_id: user_id} when not is_nil(user_id) ->
        redirect(conn, to: append_query(~p"/stats/users/#{user_id}", conn))

      _ ->
        redirect(conn, to: ~p"/stats/users")
    end
  end

  def stats_member(conn, _params), do: redirect(conn, to: ~p"/stats/users")

  @doc """
  ``/admin/users/:user_id/stats`` → ``/stats/users/:user_id``.

  La página de stats por usuario se promovió de /admin a la sección
  /stats. Query string preservado.
  """
  def user_stats(conn, %{"user_id" => user_id}) do
    redirect(conn, to: append_query(~p"/stats/users/#{user_id}", conn))
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
