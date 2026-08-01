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
            base_url: "https://api-#{u}.example.com/v1"
          },
          attrs
        )
      )

    provider
  end

  ## Permissions -----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/providers")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/providers")
  end

  test "admin sees the provider list with a created provider", %{conn: conn} do
    u = unique()
    provider = create_provider(%{name: "listed-prov-#{u}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/providers")

    assert html =~ "Proveedores"
    assert has_element?(view, "#providers-#{provider.id}")
    refute has_element?(view, "#providers-empty")
  end

  ## Provider CRUD ---------------------------------------------------------

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
          base_url: "https://api.anthropic.com/v1"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor creado."
    assert html =~ "anthropic"
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
          base_url: provider.base_url
        }
      )
      |> render_submit()

    assert html =~ "Proveedor actualizado."
    assert html =~ "nombre-cambiado"
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

  test "deleting a provider referenced by an model_provider is blocked", %{conn: conn} do
    provider = create_provider()

    u = unique()

    {:ok, alias_} =
      Providers.create_model_alias(%{
        name: "gpt-4o-#{u}",
        display_name: "GPT-4o #{u}",
        context_window: 128_000
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-blocked",
        status: "active"
      })

    {:ok, _ap} =
      Providers.create_model_provider(%{
        model_alias_id: alias_.id,
        credential_id: credential.id,
        provider_model: "gpt-4o",
        priority: 1
      })

    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "está en uso por uno o más modelos"
    assert has_element?(view, "#edit-#{provider.id}")
  end

  ## Credential management -------------------------------------------------

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
          name: "Producción",
          api_key_encrypted: "sk-tes...abcd",
          max_rpm: "500",
          max_concurrent: "10"
        }
      )
      |> render_submit()

    assert html =~ "Credencial creada."
    assert html =~ "Producción"
    assert html =~ "••••••abcd"
    assert html =~ "500"

    [cred] = Providers.list_credentials_for_provider(provider.id)

    # Edit the credential — cambiar alias y dejar API key vacío
    view |> element("#edit-credential-#{cred.id}") |> render_click()
    assert has_element?(view, "#credential-form")

    html =
      view
      |> form("#credential-form",
        credential: %{
          name: "Staging",
          api_key_encrypted: "",
          max_rpm: "300",
          max_concurrent: "5"
        }
      )
      |> render_submit()

    assert html =~ "Credencial actualizada."
    assert html =~ "Staging"
    assert html =~ "300"

    # Verificar que el API key NO se perdió
    [updated] = Providers.list_credentials_for_provider(provider.id)
    assert updated.api_key_encrypted == "sk-tes...abcd"
    assert updated.max_rpm == 300
    assert updated.max_concurrent == 5

    # Toggle it off
    html = view |> element("#toggle-credential-#{cred.id}") |> render_click()
    assert html =~ "desactivada"

    # Delete it
    html = view |> element("#delete-credential-#{cred.id}") |> render_click()
    assert html =~ "Credencial eliminada."
    refute has_element?(view, "#credential-#{cred.id}")
  end
end
