defmodule TokengateWeb.ModelsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo
  import Ecto.Query

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

  test "regular user is redirected from models page", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/models")
  end

  # -- Alias CRUD -----------------------------------------------------------

  test "admin can create a new alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    view |> element("#new-model-btn") |> render_click()

    assert has_element?(view, "#alias-form")
    assert has_element?(view, "#model_alias_prompt_cache_enabled")
    assert has_element?(view, "#model_alias_lazy_cleanup_enabled")

    html =
      view
      |> form("#alias-form", %{
        model_alias: %{
          name: "gpt-4o-test",
          display_name: "GPT-4o Test",
          context_window: 128_000,
          prompt_cache_enabled: "true",
          lazy_cleanup_enabled: "true"
        }
      })
      |> render_submit()

    assert html =~ "Modelo creado"
    assert html =~ "gpt-4o-test"

    alias_record = Tokengate.Providers.get_alias_by_name("gpt-4o-test")
    assert alias_record.prompt_cache_enabled == true
    assert alias_record.lazy_cleanup_enabled == true
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

  test "admin can set sticky_ttl_ms when creating a model provider", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")
    view |> element("#new-ap-#{alias_record.id}") |> render_click()

    # Form input is in seconds; the column is stored in ms.
    html =
      view
      |> form("#alias-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "gpt-4o-sticky",
          priority: 1,
          enabled: true,
          sticky_ttl_seconds: 60
        }
      })
      |> render_submit()

    assert html =~ "Proveedor asignado"

    ap =
      Repo.one!(
        from mp in Tokengate.Providers.ModelProvider, where: mp.model_alias_id == ^alias_record.id
      )

    assert ap.sticky_ttl_ms == 60_000
  end

  test "sticky_ttl_seconds below 1 second is rejected by the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")
    view |> element("#new-ap-#{alias_record.id}") |> render_click()

    html =
      view
      |> form("#alias-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "gpt-4o-bad",
          priority: 1,
          enabled: true,
          sticky_ttl_seconds: 0
        }
      })
      |> render_submit()

    refute html =~ "Proveedor asignado"
    # Validation error surfaces the seconds field (the form input source of truth).
    assert html =~ "sticky_ttl_seconds" or html =~ "TTL sticky"
  end

  test "sticky_ttl_seconds above 24 h is rejected by the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")
    view |> element("#new-ap-#{alias_record.id}") |> render_click()

    html =
      view
      |> form("#alias-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "gpt-4o-toobig",
          priority: 1,
          enabled: true,
          sticky_ttl_seconds: 86_401
        }
      })
      |> render_submit()

    refute html =~ "Proveedor asignado"
    assert html =~ "sticky_ttl_seconds" or html =~ "TTL sticky"
  end

  test "editing a model provider pre-fills sticky_ttl_seconds from sticky_ttl_ms", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_alias_id: alias_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-edit",
        priority: 1,
        enabled: true,
        sticky_ttl_ms: 300_000
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")
    view |> element("#edit-ap-#{ap.id}") |> render_click()

    # Form should be open with 300 (seconds) pre-filled, not 300_000.
    html = render(view)
    assert has_element?(view, "#alias-provider-form")
    assert html =~ ~s(value="300")
    refute html =~ ~s(value="300000")
  end

  test "admin can reorder provider priorities via drag-drop event", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    ap1 = create_model_provider(alias_record, provider, %{priority: 1})
    ap2 = create_model_provider(alias_record, provider, %{priority: 2})
    ap3 = create_model_provider(alias_record, provider, %{priority: 3})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    # Drag ap3 to the top
    render_hook(view, "reorder_providers", %{
      "alias_id" => alias_record.id,
      "ids" => [ap3.id, ap1.id, ap2.id]
    })

    assert Providers.get_model_provider!(ap3.id).priority == 1
    assert Providers.get_model_provider!(ap1.id).priority == 2
    assert Providers.get_model_provider!(ap2.id).priority == 3
  end

  test "reorder rejects ids from another alias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_a = create_alias()
    alias_b = create_alias()

    ap_a = create_model_provider(alias_a, provider, %{priority: 1})
    ap_b = create_model_provider(alias_b, provider, %{priority: 7})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/models")

    render_hook(view, "reorder_providers", %{
      "alias_id" => alias_a.id,
      "ids" => [ap_b.id]
    })

    # Foreign id was rejected — priorities untouched
    assert Providers.get_model_provider!(ap_a.id).priority == 1
    assert Providers.get_model_provider!(ap_b.id).priority == 7
  end

  test "shows credential alias badge when the credential has a name", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    alias_record = create_alias()

    u = unique()

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "prod-openrouter",
        api_key_encrypted: "sk-#{u}",
        status: "active"
      })

    {:ok, _ap} =
      Providers.create_model_provider(%{
        model_alias_id: alias_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-#{u}",
        priority: 1,
        enabled: true
      })

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/models")

    assert html =~ "prod-openrouter"
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

  test "regular user is redirected from models (admin-only)", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    _alias_record = create_alias()
    conn = login(conn, admin, admin_password)
    {:ok, _view, _html} = live(conn, ~p"/dashboard/models")

    # Now login as regular user — should be redirected
    %{user: user, password: password} = register("user")
    conn = login(Phoenix.ConnTest.build_conn(), user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/models")
  end
end
