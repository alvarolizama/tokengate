defmodule TokengateWeb.AliasesLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "alias-#{u}@example.com",
        name: "User #{u}",
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

  defp create_org do
    u = unique()
    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})
    org
  end

  defp create_provider(attrs \\ %{}) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{
            name: "Provider #{u}",
            base_url: "http://localhost:1",
            billing_type: "pay_per_token"
          },
          attrs
        )
      )

    provider
  end

  defp create_alias(org, attrs \\ %{}) do
    u = unique()

    {:ok, alias_record} =
      Providers.create_model_alias(
        Map.merge(
          %{
            organization_id: org.id,
            name: "alias-#{u}",
            display_name: "Alias #{u}",
            market_input_price_per_1m: "1.50",
            market_output_price_per_1m: "3.00",
            context_window: 128_000,
            routing_strategy: "priority"
          },
          attrs
        )
      )

    alias_record
  end

  defp create_alias_provider(model_alias, provider, attrs \\ %{}) do
    u = unique()

    {:ok, ap} =
      Providers.create_alias_provider(
        Map.merge(
          %{
            model_alias_id: model_alias.id,
            provider_id: provider.id,
            provider_model: "gpt-4o-#{u}",
            priority: 1,
            enabled: true
          },
          attrs
        )
      )

    ap
  end

  # -- Permissions ----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/aliases")
  end

  test "admin sees the create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/aliases")

    assert has_element?(view, "#new-alias-btn")
    assert html =~ "Aliases de Modelos"
  end

  test "regular user sees read-only view without create button", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/aliases")

    refute has_element?(view, "#new-alias-btn")
    assert html =~ "Aliases de Modelos"
  end

  test "regular user cannot trigger new_alias event", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    # Trigger the event directly — it should be blocked by the permission check
    view |> render_click("new_alias")

    # Form should not appear
    refute has_element?(view, "#alias-form")
    assert render(view) =~ "No tienes permisos"
  end

  # -- Alias CRUD -----------------------------------------------------------

  test "admin can create a new alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    view |> element("#new-alias-btn") |> render_click()

    assert has_element?(view, "#alias-form")

    html =
      view
      |> form("#alias-form", %{
        model_alias: %{
          organization_id: org.id,
          name: "gpt-4o-test",
          display_name: "GPT-4o Test",
          market_input_price_per_1m: "2.50",
          market_output_price_per_1m: "5.00",
          context_window: 128_000,
          routing_strategy: "priority"
        }
      })
      |> render_submit()

    assert html =~ "Alias creado"
    assert html =~ "gpt-4o-test"
  end

  test "admin can edit an existing alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    alias_record = create_alias(org)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    view |> element("#edit-alias-#{alias_record.id}") |> render_click()

    assert has_element?(view, "#alias-form")

    html =
      view
      |> form("#alias-form", %{
        model_alias: %{
          organization_id: org.id,
          name: alias_record.name,
          display_name: "Updated Display Name",
          market_input_price_per_1m: "9.99",
          market_output_price_per_1m: "19.99",
          context_window: 200_000,
          routing_strategy: "round_robin"
        }
      })
      |> render_submit()

    assert html =~ "Alias actualizado"
    assert html =~ "Updated Display Name"
    assert html =~ "Round Robin"
  end

  test "admin can delete an alias without providers", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    alias_record = create_alias(org)
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/aliases")
    assert html =~ alias_record.name

    view |> element("#delete-alias-#{alias_record.id}") |> render_click()

    html = render(view)
    assert html =~ "Alias eliminado"
    refute html =~ alias_record.name
  end

  test "admin cannot delete an alias with providers assigned", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider()
    alias_record = create_alias(org)
    create_alias_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    view |> element("#delete-alias-#{alias_record.id}") |> render_click()

    html = render(view)
    assert html =~ "No se puede eliminar"
  end

  # -- Alias provider management -------------------------------------------

  test "admin can assign a provider to an alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider()
    alias_record = create_alias(org)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    # The new_alias_provider button is inline in each alias card
    assert has_element?(view, "#new-ap-#{alias_record.id}")

    view |> element("#new-ap-#{alias_record.id}") |> render_click()

    assert has_element?(view, "#alias-provider-form")

    html =
      view
      |> form("#alias-provider-form", %{
        alias_provider: %{
          provider_id: provider.id,
          provider_model: "claude-3-opus",
          priority: 1,
          enabled: true
        }
      })
      |> render_submit()

    assert html =~ "Proveedor asignado"
    assert html =~ "claude-3-opus"
  end

  test "admin can toggle alias_provider enabled state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider()
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/aliases")

    view |> element("#toggle-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "desactivado"
  end

  test "admin can delete an alias_provider", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider()
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/aliases")
    assert html =~ ap.provider_model

    view |> element("#delete-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "Proveedor eliminado"
  end

  # -- Empty state ----------------------------------------------------------

  test "shows empty state when no aliases exist", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/dashboard/aliases")

    assert html =~ "No hay aliases de modelos configurados"
  end

  # -- Read-only view shows alias data -------------------------------------

  test "regular user can see aliases but not action buttons", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    org = create_org()
    alias_record = create_alias(org)
    conn = login(conn, admin, admin_password)
    {:ok, _view, _html} = live(conn, ~p"/dashboard/aliases")

    # Now login as regular user
    %{user: user, password: password} = register("user")
    conn = login(Phoenix.ConnTest.build_conn(), user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/aliases")

    assert html =~ alias_record.name
    refute has_element?(view, "#edit-alias-#{alias_record.id}")
    refute has_element?(view, "#delete-alias-#{alias_record.id}")
  end
end
