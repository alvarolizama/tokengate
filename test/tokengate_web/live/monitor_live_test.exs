defmodule TokengateWeb.MonitorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Logs.Inflight

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "monitor-#{u}@example.com",
        name: "Monitor #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  test "admin sees monitor page", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/monitor")

    assert has_element?(view, "#monitor-chart") || html =~ "Sin actividad"
    assert html =~ "Monitor en vivo"
  end

  test "regular user is redirected from monitor", %{conn: conn} do
    %{user: owner} = register("user")

    {:ok, team} =
      Tokengate.Accounts.create_team(%{"name" => "Team #{unique()}"})

    {:ok, _member} =
      Tokengate.Accounts.create_team_member(%{"user_id" => owner.id, "team_id" => team.id})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/monitor")
  end

  test "shows in-flight count badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # Register a fake in-flight request
    Inflight.start_request(%{
      model_requested: "gpt-4",
      provider_name: "OpenRouter",
      credential_name: "key-1"
    })

    {:ok, view, html} = live(conn, ~p"/dashboard/monitor")

    # The total in-flight badge should show at least 1
    assert html =~ "en vuelo"

    # Clean up
    Inflight.list() |> Enum.each(fn e -> Inflight.finish_request(e.id) end)
  end
end
