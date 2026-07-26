defmodule TokengateWeb.RoutingRulesLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register_admin do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "admin-#{u}@example.com",
        name: "Admin #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp register_user do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: "user"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp org_with_alias do
    u = unique()
    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})

    {:ok, alias_} =
      Providers.create_model_alias(%{
        organization_id: org.id,
        name: "claude-sonnet-#{u}",
        display_name: "Claude Sonnet #{u}",
        context_window: 200_000,
        market_input_price_per_1m: "3.0",
        market_output_price_per_1m: "15.0"
      })

    %{org: org, alias: alias_}
  end

  defp create_rule(org, alias_, attrs \\ %{}) do
    {:ok, rule} =
      Providers.create_routing_rule(
        Map.merge(
          %{
            organization_id: org.id,
            name: "rule-#{unique()}",
            conditions: %{"context_length" => "> 100000"},
            target_alias_id: alias_.id,
            priority: 1,
            enabled: true
          },
          attrs
        )
      )

    rule
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/routing-rules")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/routing-rules")
  end

  test "admin sees the rules list and empty state", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/routing-rules")

    assert html =~ "Routing Rules"
    assert has_element?(view, "#rules-empty")
  end

  test "admin creates a rule with predefined conditions", %{conn: conn} do
    %{org: org, alias: alias_} = org_with_alias()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/routing-rules")

    view |> element("#new-rule-btn") |> render_click()
    assert has_element?(view, "#rule-form")

    html =
      view
      |> form("#rule-form",
        rule: %{
          organization_id: org.id,
          name: "long-context-to-anthropic",
          target_alias_id: alias_.id,
          priority: "1",
          enabled: "true"
        },
        conditions: %{
          context_length_min: "100000",
          has_images: "",
          agent_type: "claude-code"
        }
      )
      |> render_submit()

    assert html =~ "Regla creada correctamente."
    assert html =~ "long-context-to-anthropic"
    assert html =~ "contexto &gt; 100000"
    assert html =~ "agente: claude-code"

    [rule] = Providers.list_routing_rules_for_organization(org.id)
    assert rule.conditions == %{"context_length" => "> 100000", "agent_type" => "claude-code"}
  end

  test "admin edits a rule", %{conn: conn} do
    %{org: org, alias: alias_} = org_with_alias()
    rule = create_rule(org, alias_)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/routing-rules")

    view |> element("#edit-#{rule.id}") |> render_click()
    assert has_element?(view, "#rule-form")

    html =
      view
      |> form("#rule-form",
        rule: %{
          organization_id: org.id,
          name: "renamed-rule",
          target_alias_id: alias_.id,
          priority: "2"
        },
        conditions: %{context_length_min: "50000", has_images: "true", agent_type: ""}
      )
      |> render_submit()

    assert html =~ "Regla actualizada correctamente."
    assert html =~ "renamed-rule"

    updated = Providers.get_routing_rule!(rule.id)
    assert updated.priority == 2
    assert updated.conditions == %{"context_length" => "> 50000", "has_images" => true}
  end

  test "admin toggles a rule enabled/disabled", %{conn: conn} do
    %{org: org, alias: alias_} = org_with_alias()
    rule = create_rule(org, alias_)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/routing-rules")

    html = view |> element("#toggle-#{rule.id}") |> render_click()
    assert html =~ "Deshabilitada"
    refute Providers.get_routing_rule!(rule.id).enabled

    html = view |> element("#toggle-#{rule.id}") |> render_click()
    assert html =~ "Activa"
    assert Providers.get_routing_rule!(rule.id).enabled
  end

  test "admin deletes a rule", %{conn: conn} do
    %{org: org, alias: alias_} = org_with_alias()
    rule = create_rule(org, alias_)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/routing-rules")

    html = view |> element("#delete-#{rule.id}") |> render_click()

    assert html =~ "Regla eliminada."
    refute has_element?(view, "#rule-#{rule.id}")
    assert Providers.get_routing_rule(rule.id) == nil
  end
end
