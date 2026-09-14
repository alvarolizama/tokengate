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

  # The providers list defaults to the builtin tab; custom providers only
  # render after switching. Helper: mount + switch to the Custom tab. The
  # tabs only render when at least one provider is visible — when the list
  # is empty the tab is absent and we stay on the default.
  defp live_custom_tab(conn) do
    {:ok, view, _html} = live(conn, ~p"/admin/providers")

    view =
      if Phoenix.LiveViewTest.has_element?(view, "#tab-providers-custom") do
        view |> Phoenix.LiveViewTest.element("#tab-providers-custom") |> render_click()
        view
      else
        view
      end

    {:ok, view, render(view)}
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
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin/providers")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/providers")
  end

  test "admin sees the provider list with a created provider", %{conn: conn} do
    u = unique()
    provider = create_provider(%{name: "listed-prov-#{u}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live_custom_tab(conn)

    assert html =~ "Proveedores"
    assert has_element?(view, "#providers-#{provider.id}")
    refute has_element?(view, "#providers-empty")
  end

  ## Provider CRUD ---------------------------------------------------------

  test "admin creates a provider", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

    view |> element("#new-custom-provider-btn") |> render_click()
    assert has_element?(view, "#provider-form")

    html =
      view
      |> form("#provider-form",
        provider: %{
          name: "anthropic",
          base_url: "https://api.anthropic.com/v1",
          billing_type: "pay_per_token"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor creado."

    # The new custom provider lives on the Custom tab.
    view |> element("#tab-providers-custom") |> render_click()
    assert render(view) =~ "anthropic"
  end

  test "admin edits a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

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
    {:ok, view, _html} = live_custom_tab(conn)

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "Proveedor eliminado."
    refute has_element?(view, "#edit-#{provider.id}")
  end

  test "deleting a provider referenced by an model_provider is blocked", %{conn: conn} do
    provider = create_provider()

    u = unique()

    {:ok, model_} =
      Providers.create_model(%{
        name: "gpt-4o-#{u}",
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
        model_id: model_.id,
        credential_id: credential.id,
        provider_model: "gpt-4o",
        priority: 1
      })

    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "está en uso por uno o más modelos"
    assert has_element?(view, "#edit-#{provider.id}")
  end

  ## Credential management -------------------------------------------------

  test "admin manages credentials for a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

    # Credentials panel is always open
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

    # Edit the credential — cambiar model y dejar API key vacío
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
    html = view |> element("#toggle-credential-btn-#{cred.id}") |> render_click()
    assert html =~ "desactivada"

    # Delete it
    html = view |> element("#delete-credential-#{cred.id}") |> render_click()
    assert html =~ "Credencial eliminada."
    refute has_element?(view, "#credential-#{cred.id}")
  end

  ## Builtin (catalog) providers ------------------------------------------------

  test "builtin providers offer no Editar button", %{conn: conn} do
    # Builtins are seeded like CatalogSync does (raw change, bypassing the
    # operator changeset that locks identity fields).
    {:ok, builtin} =
      %Providers.Provider{}
      |> Ecto.Changeset.change(
        key: "catalog-prov-#{unique()}",
        name: "Catalog Prov #{unique()}",
        base_url: "https://catalog-#{unique()}.example.com/v1",
        source: "builtin",
        dialect: "openai",
        billing_type: "pay_per_token",
        capabilities: ["llm"],
        status: "active"
      )
      |> Tokengate.Repo.insert()

    # Builtins only surface in the list once a credential exists
    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: builtin.id,
        name: "Producción",
        api_key_encrypted: "sk-builtin-test",
        status: "active"
      })

    custom = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    # Builtin card lives on the DEFAULT tab — plain mount, no switch.
    {:ok, view, _html} = live(conn, ~p"/admin/providers")

    # Builtin: no edit affordance at all (identity is catalog-owned; boot
    # sync would overwrite any edit). Custom keeps it — on ITS tab.
    refute has_element?(view, "#edit-#{builtin.id}")
    refute has_element?(view, "#providers-#{custom.id}")

    view |> element("#tab-providers-custom") |> render_click()
    assert has_element?(view, "#edit-#{custom.id}")
    # Both keep the status toggle
    assert has_element?(view, "#toggle-provider-#{builtin.id}") ||
             has_element?(view, "#toggle-provider-#{custom.id}")
  end

  test "custom edit modal keeps identity fields editable", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

    view |> element("#edit-#{provider.id}") |> render_click()

    assert has_element?(view, "#provider-form")
    refute has_element?(view, "#provider-form input[name='provider[name]'][disabled]")
    refute has_element?(view, "#provider-form input[name='provider[base_url]'][disabled]")
  end

  test "credential button is labeled 'API key' to distinguish from activating providers", %{
    conn: conn
  } do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_custom_tab(conn)

    assert has_element?(view, "#new-credential-#{provider.id}")
    assert render(view) =~ "API key"
  end
end
