defmodule TokengateWeb.BudgetsLiveTest do
  @moduledoc """
  Tests for the Budget admin page: caps (global + per-user) and exemption
  management per scope.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Budgets, GlobalSettings}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "budget-#{u}@example.com",
        name: "Budget #{u}",
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

  describe "access" do
    test "renders caps and empty exemption lists for admin", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      assert has_element?(view, "#global-cap-form")
      assert has_element?(view, "#per-user-cap-form")
      assert has_element?(view, "#global-exemption-form")
      assert has_element?(view, "#user-exemption-form")
      assert render(view) =~ "Límite de gasto diario global"
      assert render(view) =~ "Límite diario por usuario"
      assert render(view) =~ "Sin exclusiones"
    end

    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")

      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/budgets")
    end
  end

  describe "caps" do
    test "saving global daily cap updates the setting", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      view
      |> form("#global-cap-form", global_settings: %{daily_max_spend_usd: "50.00"})
      |> render_submit()

      assert render(view) =~ "Límite diario global actualizado"
      assert render(view) =~ "$50.00"
      assert GlobalSettings.get_daily_cap() |> Decimal.to_string() =~ "50"
    end

    test "saving per-user daily cap updates the setting", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      view
      |> form("#per-user-cap-form", global_settings: %{daily_max_per_user_usd: "5.00"})
      |> render_submit()

      assert render(view) =~ "Límite diario por usuario actualizado"

      assert GlobalSettings.get_per_user_daily_cap()
             |> Decimal.to_string() =~ "5.0"
    end
  end

  describe "exemptions" do
    test "adds and removes a user exemption from the global scope", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, target} =
        Accounts.register_user(%{
          email: "target-#{unique()}@example.com",
          name: "Target",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      view
      |> form("#global-exemption-form", global_subject: %{subject_type: "user"})
      |> render_change()

      view
      |> form("#global-exemption-form",
        global_subject: %{subject_type: "user", subject_id: target.id}
      )
      |> render_submit()

      assert render(view) =~ target.email
      assert render(view) =~ "Exención agregada."

      # Remove it again
      exemption = hd(Budgets.Exemptions.list_for_scope("global_daily"))

      view
      |> element("#global-exemption-" <> exemption.id <> " button")
      |> render_click()

      assert render(view) =~ "Exención eliminada."
      assert render(view) =~ "Sin exclusiones"
    end

    test "adds a team exemption to the per-user scope", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      {:ok, team} = Accounts.create_team(%{name: "Budget Team #{unique()}"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      # Switch the subject_type select to "team" so the subject select
      # re-renders with team options before submitting.
      view
      |> form("#user-exemption-form", user_subject: %{subject_type: "team"})
      |> render_change()

      view
      |> form("#user-exemption-form",
        user_subject: %{subject_type: "team", subject_id: team.id}
      )
      |> render_submit()

      assert render(view) =~ "Budget Team"
      assert render(view) =~ "Exención agregada."
    end

    test "duplicate exemption shows an error and keeps the list intact", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, target} =
        Accounts.register_user(%{
          email: "dup-#{unique()}@example.com",
          name: "Dup",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/budgets")

      submit = fn view ->
        view
        |> form("#global-exemption-form",
          global_subject: %{subject_type: "user", subject_id: target.id}
        )
        |> render_submit()
      end

      submit.(view)
      assert render(view) =~ "Exención agregada."

      count_before = length(Budgets.Exemptions.list_for_scope("global_daily"))

      submit.(view)
      assert render(view) =~ "No se pudo agregar la exención"
      assert length(Budgets.Exemptions.list_for_scope("global_daily")) == count_before
    end
  end
end
