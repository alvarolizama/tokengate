defmodule TokengateWeb.RedirectController do
  @moduledoc """
  Permanent redirects for moved dashboard pages.
  """

  use TokengateWeb, :controller

  @doc """
  ``/dashboard/credits`` y ``/stats/credits`` → ``/stats/overview``.

  El tab Créditos se disolvió: el uso de presupuesto (gasto vs límite)
  vive dentro de cada dimensión — barra org en En vivo/Resumen, columnas
  en Usuarios/Grupos/Servicios.
  """
  def stats_credits(conn, _params) do
    redirect(conn, to: ~p"/stats/overview")
  end

  @doc """
  ``/credit/subscriptions`` → ``/budget/topups``.

  Las suscripciones desaparecieron del modelo: el presupuesto se gobierna con el
  techo mensual del sujeto más los top-ups. La página se elimina, pero un
  bookmark viejo no puede quedar en 404.
  """
  def credit_subscriptions(conn, _params) do
    redirect(conn, to: append_query(~p"/budget/topups", conn))
  end

  @doc """
  ``/access/groups[...rest]`` → ``/budget/months[...rest]``.

  Los grupos eran el contenedor del que cada usuario hereda su presupuesto
  mensual; la sección «Crédito» pasó a «Presupuesto» y sus rutas a ``/budget``.
  La subruta se conserva (``/access/groups/:id/members`` →
  ``/budget/months/:id/members``) y la query string también.
  """
  def budget_months(conn, params) do
    redirect(conn, to: append_query(append_rest(~p"/budget/months", params), conn))
  end

  @doc "``/credit/topups[...rest]`` → ``/budget/topups[...rest]``."
  def budget_topups(conn, params) do
    redirect(conn, to: append_query(append_rest(~p"/budget/topups", params), conn))
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

  @doc "``/dashboard/calculator`` → ``/calculator``"
  def calculator(conn, _params) do
    redirect(conn, to: append_query(~p"/calculator", conn))
  end

  @doc "``/logs`` → ``/operations/monitoring``"
  def logs(conn, _params) do
    redirect(conn, to: append_query(~p"/operations/monitoring", conn))
  end

  @doc "``/dashboard/services/supervised`` → ``/services/supervised``"
  def supervised_services(conn, _params) do
    redirect(conn, to: append_query(~p"/services/supervised", conn))
  end

  defp append_query(path, conn) do
    case conn.query_string do
      "" -> path
      qs -> "#{path}?#{qs}"
    end
  end

  # Preserva la subruta capturada por un glob (`*rest`) al mover un prefijo.
  defp append_rest(path, params) do
    case params |> Map.get("rest", []) |> List.wrap() |> Enum.join("/") do
      "" -> path
      rest -> "#{path}/#{rest}"
    end
  end
end
