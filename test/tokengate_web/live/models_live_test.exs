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
        email: "model-#{u}@example.com",
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

  defp create_model(attrs \\ %{}) do
    u = unique()

    {:ok, model_record} =
      Providers.create_model(
        Map.merge(
          %{
            name: "model-#{u}",
            context_window: 128_000,
            pinned: true
          },
          attrs
        )
      )

    model_record
  end

  defp create_model_provider(model, provider, attrs \\ %{}) do
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
            model_id: model.id,
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
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/catalog/models")
  end

  test "admin sees the create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/catalog/models")

    assert has_element?(view, "#new-model-btn")
    assert html =~ "Modelos"
  end

  test "regular user is redirected from models page", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/catalog/models")
  end

  # -- Alias CRUD -----------------------------------------------------------

  test "admin can create a new model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()

    assert has_element?(view, "#model-form")

    html =
      view
      |> form("#model-form", %{
        model: %{
          name: "gpt-4o-test",
          context_window: 128_000
        }
      })
      |> render_submit()

    assert html =~ "Modelo creado"

    # No filters left on the page: a freshly created (unpinned) model shows.
    html = render(view)
    assert html =~ "gpt-4o-test"

    model_record = Tokengate.Providers.get_model_by_name("gpt-4o-test")
    # The optimization checkboxes are gone from the form: the transforms are
    # mandatory for chat models, so the schema defaults simply hold.
    assert model_record.prompt_cache_enabled == false
    assert model_record.lazy_cleanup_enabled == false
  end

  test "model form renders informational market prices and persists them", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()

    assert has_element?(view, "#model_market_input_price_per_1m")
    assert has_element?(view, "#model_market_output_price_per_1m")
    assert has_element?(view, "#model_market_cache_price_per_1m")

    html =
      view
      |> form("#model-form", %{
        model: %{
          name: "gpt-4o-market",
          context_window: 128_000,
          market_input_price_per_1m: "1.25",
          market_output_price_per_1m: "10",
          market_cache_price_per_1m: "0.125"
        }
      })
      |> render_submit()

    assert html =~ "Modelo creado"

    # Market prices surface on the model card row (display-only).
    html = render(view)
    assert html =~ "gpt-4o-market"
    # Exact single-line render (HEEx must not split "$" from the value).
    assert html =~ "· in $1.25 · out $10 · cache $0.125 /1M"

    model_record = Tokengate.Providers.get_model_by_name("gpt-4o-market")

    assert Decimal.eq?(model_record.market_input_price_per_1m, Decimal.new("1.25"))
    assert Decimal.eq?(model_record.market_output_price_per_1m, Decimal.new("10"))
    assert Decimal.eq?(model_record.market_cache_price_per_1m, Decimal.new("0.125"))
  end

  test "admin can edit an existing model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_record = create_model()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#edit-model-#{model_record.id}") |> render_click()

    assert has_element?(view, "#model-form")

    html =
      view
      |> form("#model-form", %{
        model: %{
          name: "gpt-4o-renamed",
          context_window: 200_000
        }
      })
      |> render_submit()

    assert html =~ "Modelo actualizado"
    assert html =~ "gpt-4o-renamed"
  end

  test "admin can delete an model without providers", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_record = create_model()
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/catalog/models")
    assert html =~ model_record.name

    view |> element("#delete-model-#{model_record.id}") |> render_click()

    html = render(view)
    assert html =~ "Modelo eliminado"
    refute html =~ model_record.name
  end

  test "admin cannot delete an model with providers assigned", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()
    create_model_provider(model_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#delete-model-#{model_record.id}") |> render_click()

    html = render(view)
    assert html =~ "No se puede eliminar"
  end

  # -- Alias provider management -------------------------------------------

  test "admin can assign a provider to an model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    # Create credential before mounting LiveView so it appears in the select
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    # The new_model_provider button is inline in each model card
    assert has_element?(view, "#new-ap-#{model_record.id}")

    view |> element("#new-ap-#{model_record.id}") |> render_click()

    assert has_element?(view, "#model-provider-form")

    html =
      view
      |> form("#model-provider-form", %{
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
    model_record = create_model()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-ap-#{model_record.id}") |> render_click()

    # Form input is in seconds; the column is stored in ms.
    html =
      view
      |> form("#model-provider-form", %{
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
        from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model_record.id
      )

    assert ap.sticky_ttl_ms == 60_000
  end

  test "admin can set per-provider request overrides when creating a model provider", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    {_provider, credential} = fw_fixtures()
    model_record = create_model()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-ap-#{model_record.id}") |> render_click()

    # Selecting the fireworks credential reveals the priority checkbox.
    view
    |> form("#model-provider-form", %{
      model_provider: %{credential_id: credential.id, provider_model: "fw", priority: 1}
    })
    |> render_change()

    html =
      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "fw",
          priority: 1,
          enabled: true,
          service_tier_priority: true
        }
      })
      |> render_submit()

    assert html =~ "Proveedor asignado"

    ap =
      Repo.one!(
        from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model_record.id
      )

    # The checkbox owns extra_body's managed key.
    assert ap.extra_body == %{"service_tier" => "priority"}
    # Raw overrides stay at their no-op defaults (not submittable from the UI).
    assert ap.omit_body_fields == []
    assert ap.omit_headers == []
  end

  test "edit form no longer renders the raw override inputs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    mp =
      Tokengate.Repo.insert!(%Tokengate.Providers.ModelProvider{
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "fireworks-strict",
        enabled: true,
        extra_body: %{"service_tier" => "priority"},
        omit_body_fields: ["session_id"],
        omit_headers: ["user-agent"]
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#edit-ap-#{mp.id}") |> render_click()

    # The raw override inputs are gone from the form entirely.
    refute has_element?(view, "input[name='model_provider[omit_body_fields_csv]']")
    refute has_element?(view, "input[name='model_provider[omit_headers_csv]']")
    refute has_element?(view, "textarea[name='model_provider[extra_body_json]']")
  end

  describe "fireworks-backed provider form" do
    defp fw_fixtures do
      Repo.get_by(Tokengate.Providers.Provider, key: "fireworks-ai")
      |> case do
        nil -> :ok
        builtin -> {:ok, _} = Repo.delete(builtin)
      end

      provider =
        create_provider(%{
          key: "fireworks-ai",
          name: "Fireworks AI (probe)",
          base_url: "http://localhost:1"
        })

      credential =
        Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
          provider_id: provider.id,
          name: "FW Cred #{unique()}",
          api_key_encrypted: "fw-test",
          status: "active"
        })

      {provider, credential}
    end

    test "saving a fireworks provider leaves cache_control off; regular defaults on", %{
      conn: conn
    } do
      %{user: admin, password: password} = register("admin")
      {_fw_provider, fw_cred} = fw_fixtures()

      regular_provider = create_provider()
      model_a = create_model()
      model_b = create_model()

      regular_cred =
        Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
          provider_id: regular_provider.id,
          name: "Reg Cred #{unique()}",
          api_key_encrypted: "sk-reg",
          status: "active"
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/catalog/models")

      # Regular provider: save → cache_control ON by default.
      view |> element("#new-ap-#{model_a.id}") |> render_click()

      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: regular_cred.id,
          provider_model: "m",
          priority: 1,
          enabled: true
        }
      })
      |> render_submit()

      regular =
        Repo.one!(from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model_a.id)

      assert regular.cache_control_enabled == true

      # Fireworks: select the credential (flips the form), then save → OFF.
      view |> element("#new-ap-#{model_b.id}") |> render_click()

      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: fw_cred.id,
          provider_model: "fw-m",
          priority: 1,
          enabled: true
        }
      })
      |> render_submit()

      fw =
        Repo.one!(from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model_b.id)

      assert fw.cache_control_enabled == false
    end

    test "hides cache_control and shows the service_tier checkbox for fireworks", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      # Drop the builtin row to own the unique key, then stamp it on a local
      # provider (same trick as the proxy controller test).
      Repo.get_by(Tokengate.Providers.Provider, key: "fireworks-ai")
      |> case do
        nil -> :ok
        builtin -> {:ok, _} = Repo.delete(builtin)
      end

      provider =
        create_provider(%{
          key: "fireworks-ai",
          name: "Fireworks AI (probe)",
          base_url: "http://localhost:1"
        })

      model_record = create_model()

      credential =
        Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
          provider_id: provider.id,
          name: "FW Cred",
          api_key_encrypted: "fw-test",
          status: "active"
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      # Selecting the fireworks credential flips the form.
      view
      |> form("#model-provider-form", %{
        model_provider: %{credential_id: credential.id, provider_model: "fw-model", priority: 1}
      })
      |> render_change()

      # The priority checkbox appears…
      assert has_element?(view, "input[name='model_provider[service_tier_priority]']")
      # …and the Anthropic-style cache_control toggle does NOT (it breaks
      # Fireworks: strict validation rejects the content-parts format).
      refute has_element?(view, "input[name='model_provider[cache_control_enabled]']")
      # The automatic prompt-cache note is visible.
      assert render(view) =~ "activa por defecto"
    end

    test "non-fireworks credentials keep the cache_control toggle and no priority checkbox", %{
      conn: conn
    } do
      %{user: admin, password: password} = register("admin")
      provider = create_provider()
      model_record = create_model()

      credential =
        Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
          provider_id: provider.id,
          name: "Other Cred",
          api_key_encrypted: "sk-other",
          status: "active"
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      view
      |> form("#model-provider-form", %{
        model_provider: %{credential_id: credential.id, provider_model: "any", priority: 1}
      })
      |> render_change()

      assert has_element?(view, "input[name='model_provider[cache_control_enabled]']")
      refute has_element?(view, "input[name='model_provider[service_tier_priority]']")
    end
  end

  test "sticky_ttl_seconds below 1 second is rejected by the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-ap-#{model_record.id}") |> render_click()

    html =
      view
      |> form("#model-provider-form", %{
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
    model_record = create_model()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-ap-#{model_record.id}") |> render_click()

    html =
      view
      |> form("#model-provider-form", %{
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
    model_record = create_model()

    credential =
      Tokengate.Repo.insert!(%Tokengate.Providers.Credential{
        provider_id: provider.id,
        name: "Test Cred",
        api_key_encrypted: "sk-...",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-edit",
        priority: 1,
        enabled: true,
        sticky_ttl_ms: 300_000
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#edit-ap-#{ap.id}") |> render_click()

    # Form should be open with 300 (seconds) pre-filled, not 300_000.
    html = render(view)
    assert has_element?(view, "#model-provider-form")
    assert html =~ ~s(value="300")
    refute html =~ ~s(value="300000")
  end

  test "admin can reorder provider priorities via drag-drop event", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    ap1 = create_model_provider(model_record, provider, %{priority: 1})
    ap2 = create_model_provider(model_record, provider, %{priority: 2})
    ap3 = create_model_provider(model_record, provider, %{priority: 3})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    # Drag ap3 to the top
    render_hook(view, "reorder_providers", %{
      "model_id" => model_record.id,
      "ids" => [ap3.id, ap1.id, ap2.id]
    })

    assert Providers.get_model_provider!(ap3.id).priority == 1
    assert Providers.get_model_provider!(ap1.id).priority == 2
    assert Providers.get_model_provider!(ap2.id).priority == 3
  end

  test "reorder rejects ids from another model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_a = create_model()
    model_b = create_model()

    ap_a = create_model_provider(model_a, provider, %{priority: 1})
    ap_b = create_model_provider(model_b, provider, %{priority: 7})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    render_hook(view, "reorder_providers", %{
      "model_id" => model_a.id,
      "ids" => [ap_b.id]
    })

    # Foreign id was rejected — priorities untouched
    assert Providers.get_model_provider!(ap_a.id).priority == 1
    assert Providers.get_model_provider!(ap_b.id).priority == 7
  end

  test "shows credential model badge when the credential has a name", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

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
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-#{u}",
        priority: 1,
        enabled: true
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    html = render(view)

    assert html =~ "prod-openrouter"
  end

  test "admin can toggle model_provider enabled state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()
    ap = create_model_provider(model_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#toggle-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "desactivado"
  end

  test "edit pre-fills the member search input with the full email", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: target, password: _} = register("user")
    provider = create_provider()
    model_record = create_model()

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    # Add target as a group_member of any group so members_for_select can preload it.
    {:ok, group} = Accounts.create_group(%{name: "Group #{unique()}"})
    {:ok, group_member} = Accounts.create_group_member(%{group_id: group.id, user_id: target.id})

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-exc",
        priority: 1,
        enabled: true,
        exclusive_to_group_member_id: group_member.id
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#edit-ap-#{ap.id}") |> render_click()

    html = render(view)

    # The member search input should be pre-filled with the FULL email,
    # not a single character, so the user sees who is bound.
    assert html =~ ~s(value="#{target.email}")

    assert has_element?(
             view,
             ~s(input[name="model_provider[scope_member_id_display]"])
           )

    # The dropdown must start CLOSED in edit mode: opening the modal never
    # auto-expands it anymore.
    refute html =~ "(actual)"

    # Opening the picker renders the currently-bound member as an item,
    # marked as (actual).
    view |> render_click("open_scope_picker", %{"picker" => "member"})
    assert render(view) =~ "(actual)"

    # Picking the item reflects its label into the search input and closes
    # the dropdown.
    view
    |> render_click("select_scope_member_item", %{
      "member_id" => group_member.id,
      "member_label" => target.email
    })

    html = render(view)
    assert html =~ ~s(value="#{target.email}")
    refute html =~ "(actual)"

    # Click-away / Escape share the same closer and are safe when already
    # closed.
    view |> render_click("close_scope_pickers", %{})

    # Typing in the edit-mode picker filters via phx-change: being a named
    # input inside the form, its value arrives nested under its
    # model_provider[...] field name (not as %{"value"}).
    view
    |> render_change("scope_member_search", %{
      "model_provider" => %{"scope_member_id_display" => target.email}
    })

    html = render(view)
    assert html =~ ~s(value="#{target.email}")

    # Clearing the input closes the list until the field regains focus.
    view
    |> render_change("scope_member_search", %{
      "model_provider" => %{"scope_member_id_display" => ""}
    })

    refute render(view) =~ "(actual)"

    refute html =~ ~s(value="a")
  end

  test "edit pre-fills the group search input and the picker closes on pick", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()
    {:ok, group} = Accounts.create_group(%{name: "Scope #{unique()}"})

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-group",
        priority: 1,
        enabled: true,
        exclusive_to_group_id: group.id
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#edit-ap-#{ap.id}") |> render_click()

    html = render(view)

    # Prefilled with the bound group's name, dropdown born closed.
    assert has_element?(view, ~s(input[name="model_provider[scope_group_id_display]"]))
    assert html =~ ~s(value="#{group.name}")
    refute html =~ "(actual)"

    # Opening renders the bound group marked as (actual).
    view |> render_click("open_scope_picker", %{"picker" => "group"})
    assert render(view) =~ "(actual)"

    # Picking reflects the label into the input and closes the dropdown.
    view
    |> render_click("select_scope_group_item", %{
      "group_id" => group.id,
      "group_label" => group.name
    })

    html = render(view)
    assert html =~ ~s(value="#{group.name}")
    refute html =~ "(actual)"
  end

  test "creating with multiple members builds one exclusive provider per member", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    {:ok, group} = Accounts.create_group(%{name: "Group #{unique()}"})
    {:ok, tm_a} = Accounts.create_group_member(%{group_id: group.id, user_id: admin.id})

    %{user: other, password: _} = register("user2")
    {:ok, tm_b} = Accounts.create_group_member(%{group_id: group.id, user_id: other.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-ap-#{model_record.id}") |> render_click()

    # Multi-select flow: pick the member scope, accumulate two members,
    # submit once.
    view |> render_click("change_scope", %{"scope" => "member"})
    view |> render_click("toggle_scope_member", %{"member_id" => tm_a.id})
    view |> render_click("toggle_scope_member", %{"member_id" => tm_b.id})

    html =
      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "gpt-4o-multi",
          priority: 1,
          enabled: true
        }
      })
      |> render_submit()

    assert html =~ "2 proveedores asignados"

    bound_member_ids =
      Repo.all(
        from mp in Tokengate.Providers.ModelProvider,
          where: mp.model_id == ^model_record.id,
          select: mp.exclusive_to_group_member_id
      )

    assert Enum.sort(bound_member_ids) == Enum.sort([tm_a.id, tm_b.id])
  end

  test "stale provider models results are discarded when credential changes", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    {:ok, c1} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test-1",
        status: "active"
      })

    {:ok, c2} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test-2",
        status: "active"
      })

    # Provider currently bound to c2: opening the editor sets c2 as the
    # expected credential for models results. Created before live/3 so it
    # is part of the initially-mounted stream.
    {:ok, ap} =
      Providers.create_model_provider(%{
        model_id: model_record.id,
        credential_id: c2.id,
        provider_model: "gpt-4o-race",
        priority: 1,
        enabled: true
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#edit-ap-#{ap.id}") |> render_click()

    # An old credential's slow response arrives late: it must be ignored.
    send(
      view.pid,
      {:provider_models_result, c1.id, {:ok, ["stale-model-a", "stale-model-b"]}}
    )

    refute render(view) =~ "stale-model-a"

    # Current credential's response is still accepted.
    send(view.pid, {:provider_models_result, c2.id, {:ok, ["fresh-model"]}})
    assert render(view) =~ "fresh-model"
  end

  test "model_provider row surfaces credential disabled state in /catalog/models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    # Create credential under the model's model_provider, then disable it.
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    {:ok, ap} =
      Providers.create_model_provider(%{
        model_id: model_record.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-dis",
        priority: 1,
        enabled: true
      })

    # Now flip the credential to "disabled" (what /catalog/providers does).
    {:ok, _} = Providers.update_credential(credential, %{status: "disabled"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    html = render(view)

    # Effective state should be "Inactivo" even though ap.enabled is still true.
    assert html =~ "Inactivo"

    # The status badge title should explain why.
    assert html =~ "credential desactivada"

    # The toggle should show the play icon (it would not actually re-enable the
    # credential — admin must go to /catalog/providers for that).
    assert has_element?(view, "#toggle-ap-#{ap.id} span.hero-play")
    refute has_element?(view, "#toggle-ap-#{ap.id} span.hero-pause")
  end

  test "admin can delete an model_provider", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()
    ap = create_model_provider(model_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    html = render(view)
    assert html =~ ap.provider_model

    view |> element("#delete-ap-#{ap.id}") |> render_click()

    html = render(view)
    assert html =~ "Proveedor eliminado"
  end

  # -- Empty state ----------------------------------------------------------

  test "shows empty state when no models exist", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # The suite runs against a shared DB (async: false): other tests may
    # have created models already. Wipe them so the empty state holds.
    Repo.delete_all(Providers.Model)

    {:ok, _view, html} = live(conn, ~p"/catalog/models")

    assert html =~ "No hay models configurados"
    refute html =~ "No hay modelos pineados"
  end

  # -- Read-only view shows model data -------------------------------------

  test "regular user is redirected from models (admin-only)", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    _alias_record = create_model()
    conn = login(conn, admin, admin_password)
    {:ok, _view, _html} = live(conn, ~p"/catalog/models")

    # Now login as regular user — should be redirected
    %{user: user, password: password} = register("user")
    conn = login(Phoenix.ConnTest.build_conn(), user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/catalog/models")
  end

  # -- Credential daily spending cap indicator -------------------------------

  # -- Pin to top -----------------------------------------------------------

  test "admin can pin a model to the top", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _alias_a = create_model(%{name: "aa-pinned-test", pinned: false})
    model_b = create_model(%{name: "bb-pinned-test", pinned: false})
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    html = render(view)
    assert order_before?(html, "aa-pinned-test", "bb-pinned-test")

    view |> element("#pin-model-#{model_b.id}") |> render_click()

    assert Tokengate.Providers.get_model!(model_b.id).pinned == true

    html = render(view)
    assert order_before?(html, "bb-pinned-test", "aa-pinned-test")
  end

  test "admin can unpin a model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_record = create_model(%{name: "pinned-then-unpinned", pinned: true})
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#pin-model-#{model_record.id}") |> render_click()

    assert Tokengate.Providers.get_model!(model_record.id).pinned == false
  end

  # -- Collapsed providers section ------------------------------------------

  test "providers section is collapsed by default", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()
    create_model_provider(model_record, provider)
    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/catalog/models")

    assert html =~ ~s(id="model-providers-#{model_record.id}")
    assert html =~ ~s(style="display: none")
  end

  # -- Provider catalogue follows the model's own type -----------------------

  test "the provider catalogue type follows the model inside the form", %{conn: _conn} do
    emb = create_model(%{name: "emb-catalogue-model", model_type: "embedding"})
    llm = create_model(%{name: "llm-catalogue-model", model_type: "llm"})

    # The form's model decides which upstream catalogue is listed.
    assert TokengateWeb.ModelsLive.model_type_for(emb.id) == "embedding"
    assert TokengateWeb.ModelsLive.model_type_for(llm.id) == "llm"

    # No form open yet / unknown id: safe chat-model default.
    assert TokengateWeb.ModelsLive.model_type_for(nil) == "llm"
    assert TokengateWeb.ModelsLive.model_type_for(Ecto.UUID.generate()) == "llm"
  end

  # -- Type / favorites tabs are gone ---------------------------------------

  test "the list is unfiltered and carries no type tabs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _pinned = create_model(%{name: "nl-pinned-model", pinned: true})
    _unpinned = create_model(%{name: "nl-unpinned-model", pinned: false})
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/catalog/models")

    # Both pinned and unpinned models show in the single unfiltered list.
    assert html =~ "nl-pinned-model"
    assert html =~ "nl-unpinned-model"

    # The tab strip and each of its buttons are gone.
    refute has_element?(view, "#model-type-tabs")
    refute has_element?(view, "#model-type-favorites")
    refute has_element?(view, "#model-type-llm")
    refute has_element?(view, "#model-type-embedding")
    refute has_element?(view, "#model-type-all")
  end

  defp order_before?(html, first, second) do
    with {first_pos, _len} <- :binary.match(html, first),
         {second_pos, _len} <- :binary.match(html, second) do
      first_pos < second_pos
    else
      _ -> false
    end
  end
end
