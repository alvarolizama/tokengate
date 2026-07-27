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

  defp create_alias do
    u = unique()

    {:ok, alias_record} =
      Providers.create_model_alias(%{
        name: "alias-#{u}",
        display_name: "Alias #{u}",
        market_input_price_per_1m: "1.50",
        market_output_price_per_1m: "3.00",
        context_window: 128_000
      })

    alias_record
  end

  defp create_model_provider(model_alias, provider) do
    u = unique()

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-#{u}",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-#{u}",
        priority: 1,
        enabled: true
      })

    ap
  end

  defp create_pricing(ap, attrs \\ %{}) do
    {:ok, pricing} =
      Providers.create_model_pricing(
        Map.merge(
          %{
            model_provider_id: ap.id,
            input_price_per_1m: "2.50",
            output_price_per_1m: "5.00",
            effective_from: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    pricing
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

  test "admin sees the provider list and empty state", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/providers")

    assert html =~ "Proveedores"
    assert has_element?(view, "#providers-empty")
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
        context_window: 128_000,
        market_input_price_per_1m: "5.0",
        market_output_price_per_1m: "15.0"
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
          api_key_encrypted: "sk-tes...abcd",
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

  ## Pricing management ----------------------------------------------------

  test "admin can create a new pricing entry within a provider", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    # Open the pricing panel
    view |> element("#pricing-#{provider.id}") |> render_click()
    assert has_element?(view, "#pricing-panel-#{provider.id}")

    view |> element("#new-pricing-#{ap.id}") |> render_click()

    assert has_element?(view, "#pricing-form")

    html =
      view
      |> form("#pricing-form", %{
        model_pricing: %{
          model_provider_id: ap.id,
          input_price_per_1m: "3.50",
          output_price_per_1m: "7.00",
          effective_from: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
      |> render_submit()

    assert html =~ "Pricing creado"
    assert html =~ "3.50"
  end

  test "admin can edit an existing pricing entry", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    pricing = create_pricing(ap)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#pricing-#{provider.id}") |> render_click()

    view |> element("#edit-pricing-#{pricing.id}") |> render_click()

    assert has_element?(view, "#pricing-form")

    html =
      view
      |> form("#pricing-form", %{
        model_pricing: %{
          model_provider_id: ap.id,
          input_price_per_1m: "9.99",
          output_price_per_1m: "19.99",
          effective_from: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
      |> render_submit()

    assert html =~ "Pricing actualizado"
    assert html =~ "9.99"
  end

  test "admin can delete a pricing entry", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    pricing = create_pricing(ap)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#pricing-#{provider.id}") |> render_click()

    view |> element("#delete-pricing-#{pricing.id}") |> render_click()

    html = render(view)
    assert html =~ "Pricing eliminado"
    refute html =~ "2.50"
  end

  test "pricing panel shows model_providers with their pricing tables", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    provider = create_provider()
    alias_record = create_alias()
    ap = create_model_provider(alias_record, provider)
    create_pricing(ap, %{input_price_per_1m: "1.25", output_price_per_1m: "2.50"})

    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#pricing-#{provider.id}") |> render_click()

    html = render(view)
    assert html =~ provider.name
    assert html =~ "1.25"
    assert html =~ "2.50"
  end

  test "pricing panel shows empty state when provider has no models", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    provider = create_provider()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/providers")

    view |> element("#pricing-#{provider.id}") |> render_click()

    html = render(view)
    assert html =~ "No hay modelos asignados a este proveedor"
  end
end
