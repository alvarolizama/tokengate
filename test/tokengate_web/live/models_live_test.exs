defmodule TokengateWeb.ModelsLiveTest do
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

  defp create_provider(attrs \\ %{}) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{
            name: "Provider #{u}",
            base_url: "http://localhost:1"
          },
          attrs
        )
      )

    provider
  end

  defp create_alias(attrs \\ %{}) do
    u = unique()

    {:ok, alias_record} =
      Providers.create_model_alias(
        Map.merge(
          %{
            name: "alias-#{u}",
            display_name: "Alias #{u}",
            market_input_price_per_1m: "1.50",
            market_output_price_per_1m: "3.00",
            context_window: 128_000
          },
          attrs
        )
      )

    alias_record
  end

  defp create_model_provider(model_alias, provider, attrs \\ %{}) do
    u = unique()

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-#{u}",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_alias_id: model_alias.id,
            credential_id: credential.id,
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
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/models")
  end

  test "admin sees the create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/models")

    assert has_element?(view, "#new-model-btn")
    assert html =~ "Modelos"
  end

  test "regular user sees read-only view without create button", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/models")

    refute has_element?(view, "#new-model-btn")
    assert html =~ "Modelos"
  end

  test "regular user cannot trigger new_alias event", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    # Trigger the event directly — it should be blocked by the permission check
    view |> render_click("new_alias")

    # Form should not appear
    refute has_element?(view, "#alias-form")
    assert render(view) =~ "No tienes permisos"
  end

  # -- Alias CRUD -----------------------------------------------------------

  test "admin can create a new alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    view |> element("#new-model-btn") |> render_click()

    assert has_element?(view, "#alias-form")

    html =
      view
      |> form("#alias-form", %{
        model_alias: %{
          name: "gpt-4o-test",
          display_name: "GPT-4o Test",
          market_input_price_per_1m: "2.50",
          market_output_price_per_1m: "5.00",
          context_window: 128_000
        }
      })
      |> render_submit()

    assert html =~ "Modelo creado"
    assert html =~ "gpt-4o-test"
  end

  test "admin can edit an existing alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    alias_record = create_alias()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    view |> element("#edit-alias-#{alias_record.id}") |> render_click()

    assert has_element?(view, "#alias-form")

    html =
      view
      |> form("#alias-form", %{
        model_alias: %{
          name: alias_record.name,
          display_name: "Updated Display Name",
          market_input_price_per_1m: "9.99",
          market_output_price_per_1m: "19.99",
          context_window: 200_000
        }
      })
      |> render_submit()

    assert html =~ "Modelo actualizado"
    assert html =~ "Updated Display Name"
  end

  test "admin can delete an alias without providers", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    alias_record = create_alias()
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/models")
    assert html =~ alias_record.name

    view |> element("#delete-alias-#{alias_record.id}") |> render_click()

    html = render(view)
    assert html =~ "Modelo eliminado"
    refute html =~ alias_record.name
  end

  test "admin cannot delete an alias with providers assigned", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()
    create_model_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    view |> element("#delete-alias-#{alias_record.id}") |> render_click()

    html = render(view)
    assert html =~ "No se puede eliminar"
  end

  # -- Alias provider management -------------------------------------------

  test "admin can assign a provider to an alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    # Create credential before mounting LiveView so it appears in the select
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    # The new_model_provider button is inline in each alias card
    assert has_element?(view, "#new-ap-#{alias_record.id}")

    view |> element("#new-ap-#{alias_record.id}") |> render_click()

    assert has_element?(view, "#alias-provider-form")

    html =
      view
      |> form("#alias-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "claude-3-opus",
          priority: 1,
          enabled: true
        }
      })
      |> render_submit()

    assert html =~ "Proveedor asignado"
    assert html =~ "claude-3-opus"
  end

  test "admin can toggle model_provider enabled state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    view |> element("#toggle-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "desactivado"
  end

  test "admin can delete an model_provider", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/models")
    assert html =~ ap.provider_model

    view |> element("#delete-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "Proveedor eliminado"
  end

  # -- Empty state ----------------------------------------------------------

  test "shows empty state when no aliases exist", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/dashboard/models")

    assert html =~ "No hay modelos configurados"
  end

  # -- Read-only view shows alias data -------------------------------------

  test "regular user can see aliases but not action buttons", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    alias_record = create_alias()
    conn = login(conn, admin, admin_password)
    {:ok, _view, _html} = live(conn, ~p"/dashboard/models")

    # Now login as regular user
    %{user: user, password: password} = register("user")
    conn = login(Phoenix.ConnTest.build_conn(), user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/models")

    assert html =~ alias_record.name
    refute has_element?(view, "#edit-alias-#{alias_record.id}")
    refute has_element?(view, "#delete-alias-#{alias_record.id}")
  end
end
