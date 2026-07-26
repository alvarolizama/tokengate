defmodule TokengateWeb.ProvidersLiveTest do
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

  defp create_provider(attrs \\ %{}) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{
            name: "Prov #{u}",
            base_url: "https://api-#{u}.example.com",
            billing_type: "pay_per_token"
          },
          attrs
        )
      )

    provider
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/providers")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/providers")
  end

  test "admin sees the provider list and empty state", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/providers")

    assert html =~ "Proveedores"
    assert has_element?(view, "#providers-empty")
  end

  test "admin creates a provider", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#new-provider-btn") |> render_click()
    assert has_element?(view, "#provider-form")

    html =
      view
      |> form("#provider-form",
        provider: %{
          name: "anthropic",
          base_url: "https://api.anthropic.com",
          billing_type: "pay_per_token"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor creado."
    assert html =~ "anthropic"
    assert html =~ "Pay per token"
  end

  test "admin edits a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#edit-#{provider.id}") |> render_click()
    assert has_element?(view, "#provider-form")

    html =
      view
      |> form("#provider-form",
        provider: %{
          name: "nombre-cambiado",
          base_url: provider.base_url,
          billing_type: "subscription"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor actualizado."
    assert html =~ "nombre-cambiado"
    assert html =~ "Suscripción"
  end

  test "admin deletes an unreferenced provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "Proveedor eliminado."
    refute has_element?(view, "#edit-#{provider.id}")
  end

  test "deleting a provider referenced by an alias_provider is blocked", %{conn: conn} do
    provider = create_provider()

    u = unique()
    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})

    {:ok, alias_} =
      Providers.create_model_alias(%{
        organization_id: org.id,
        name: "gpt-4o-#{u}",
        display_name: "GPT-4o #{u}",
        context_window: 128_000,
        market_input_price_per_1m: "5.0",
        market_output_price_per_1m: "15.0"
      })

    {:ok, _ap} =
      Providers.create_alias_provider(%{
        model_alias_id: alias_.id,
        provider_id: provider.id,
        provider_model: "gpt-4o",
        priority: 1
      })

    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "está en uso por uno o más alias"
    assert has_element?(view, "#edit-#{provider.id}")
  end

  test "admin manages credentials for a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    # Open the credentials panel
    view |> element("#credentials-#{provider.id}") |> render_click()
    assert has_element?(view, "#credentials-panel-#{provider.id}")

    # Create a credential
    view |> element("#new-credential-#{provider.id}") |> render_click()
    assert has_element?(view, "#credential-form")

    html =
      view
      |> form("#credential-form",
        credential: %{
          provider_id: provider.id,
          api_key_encrypted: "sk-test-1234567890abcd",
          max_rpm: "500",
          max_concurrent: "10"
        }
      )
      |> render_submit()

    assert html =~ "Credencial creada."
    assert html =~ "••••••abcd"
    assert html =~ "500"

    [cred] = Providers.list_credentials_for_provider(provider.id)

    # Toggle it off
    html = view |> element("#toggle-credential-#{cred.id}") |> render_click()
    assert html =~ "desactivada"

    # Delete it
    html = view |> element("#delete-credential-#{cred.id}") |> render_click()
    assert html =~ "Credencial eliminada."
    refute has_element?(view, "#credential-#{cred.id}")
  end
end
