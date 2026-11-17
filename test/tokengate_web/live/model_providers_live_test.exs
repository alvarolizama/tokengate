defmodule TokengateWeb.ModelProvidersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "lanes-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    {:ok, user} = Accounts.update_user_locale(user, "es")

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
        Map.merge(%{name: "Prov #{u}", base_url: "https://api-#{u}.example.com/v1"}, attrs)
      )

    provider
  end

  defp create_model(attrs \\ %{}) do
    u = unique()

    {:ok, model} =
      Providers.create_model(Map.merge(%{name: "model-#{u}", context_window: 128_000}, attrs))

    model
  end

  defp create_credential(provider) do
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "Key #{unique()}",
        api_key_encrypted: "sk-test-abcd",
        status: "active"
      })

    credential
  end

  defp create_lane(model, provider, attrs \\ %{}) do
    credential = create_credential(provider)

    {:ok, lane} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_id: model.id,
            credential_id: credential.id,
            provider_model: "upstream/#{unique()}",
            priority: 1,
            enabled: true
          },
          attrs
        )
      )

    lane
  end

  ## Pools ---------------------------------------------------------------

  defp create_pool(provider, attrs \\ %{}) do
    {:ok, pool} = Providers.create_pool(provider, Map.merge(%{name: "Pool #{unique()}"}, attrs))
    pool
  end

  defp add_member(pool, credential) do
    {:ok, member} = Providers.add_pool_member(pool, credential)
    member
  end

  # Un pool con una key dentro, montado como lane del modelo. La credencial del
  # lane queda en nil: el pool es la fuente.
  defp create_pool_lane(model, provider, attrs \\ %{}) do
    pool = create_pool(provider)
    credential = create_credential(provider)
    member = add_member(pool, credential)

    {:ok, lane} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_id: model.id,
            pool_id: pool.id,
            provider_model: "upstream/pool-#{unique()}",
            priority: 2,
            enabled: true
          },
          attrs
        )
      )

    %{lane: lane, pool: pool, credential: credential, member: member}
  end

  defp admin_session(conn) do
    %{user: admin, password: password} = register("admin")
    login(conn, admin, password)
  end

  # Abre el modal de alta y elige el proveedor en el picker: es lo que habilita
  # la lista de pools (los pools son del proveedor).
  defp pick_provider(view, provider) do
    view |> element("#provider-search") |> render_change(%{"q" => provider.name})
    view |> element("#provider-row-#{provider.id}") |> render_click()
  end

  defp switch_to_pool(view) do
    view |> form("#model-provider-form", model_provider: %{source: "pool"}) |> render_change()
  end

  ## Permissions -----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    model = create_model()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/catalog/models/#{model.id}")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    model = create_model()
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/catalog/models/#{model.id}")
  end

  # Un id inexistente (o que ni siquiera es UUID) cae en el listado, no revienta.
  test "an unknown model id falls back to the models list", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/catalog/models"}}} =
             live(conn, ~p"/catalog/models/2f1c2b1e-0000-4000-8000-000000000000")

    assert {:error, {:redirect, %{to: "/catalog/models"}}} =
             live(conn, "/catalog/models/no-es-un-uuid")
  end

  ## La página -------------------------------------------------------------

  test "lists the lanes of THIS model only", %{conn: conn} do
    model = create_model()
    other = create_model()
    lane = create_lane(model, create_provider())
    foreign = create_lane(other, create_provider())

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    assert has_element?(view, "table#lanes-table")
    assert has_element?(view, "#model-provider-#{lane.id}")
    refute has_element?(view, "#model-provider-#{foreign.id}")
    refute has_element?(view, "#lanes-empty")
  end

  test "a model with no lanes shows the empty state", %{conn: conn} do
    model = create_model()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    assert has_element?(view, "#lanes-empty")
    assert has_element?(view, "#new-ap-#{model.id}")
  end

  # El alta de un lane abre con la unidad de precio del TIPO del modelo y con el
  # modelo ya fijado en el form.
  test "the assign modal opens with the model and its type unit", %{conn: conn} do
    model = create_model(%{model_type: "image"})
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()

    assert has_element?(view, "#model-provider-form")

    # La unidad nace con la del TIPO del modelo: un lane de imagen abre en
    # «por imagen», no en tokens.
    assert has_element?(
             view,
             "#model-provider-form select[name='model_provider[pricing_unit]'] option[selected][value='per_image']"
           )
  end

  test "?edit=<lane> opens that lane's form", %{conn: conn} do
    model = create_model()
    lane = create_lane(model, create_provider(), %{provider_model: "upstream/preset"})
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    assert has_element?(view, "#model-provider-form")
    assert has_element?(view, "#model-provider-form input[value='upstream/preset']")
  end

  ## Contadores del listado (helpers puros) --------------------------------

  test "lane_count and lane_provider_count read the preloaded lanes" do
    model = create_model()
    provider = create_provider()
    _lane = create_lane(model, provider)
    _lane2 = create_lane(model, provider)

    _ = {model, provider}

    assert TokengateWeb.ModelsLive.lane_count(%{model_providers: []}) == 0
    assert TokengateWeb.ModelsLive.lane_count(%{model_providers: [%{}, %{}]}) == 2

    assert TokengateWeb.ModelsLive.lane_provider_count(%{
             model_providers: [
               %{credential_id: "a"},
               %{credential_id: "a"},
               %{credential_id: "b"}
             ]
           }) == 2
  end

  test "price_summary: cheapest lane, mixed units, and no price" do
    alias TokengateWeb.ModelsLive

    # Sin precios capturados.
    assert ModelsLive.price_summary(%{model_providers: [%{pricing_unit: "per_1m_tokens"}]}) == nil

    # Todas en la misma unidad: gana la más barata.
    lanes = [
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("3.5")},
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("1.25")}
    ]

    assert {unit, amount} = ModelsLive.price_summary(%{model_providers: lanes})
    assert unit == "per_1m_tokens"
    assert Decimal.equal?(amount, Decimal.new("1.25"))

    # Unidades distintas: no hay número comparable.
    mixed = [
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("1")},
      %{pricing_unit: "per_image", unit_cost: Decimal.new("0.04")}
    ]

    assert ModelsLive.price_summary(%{model_providers: mixed}) == :mixed

    # Un lane por unidad cobra su propio campo.
    assert {"per_image", %Decimal{}} =
             ModelsLive.price_summary(%{
               model_providers: [%{pricing_unit: "per_image", unit_cost: Decimal.new("0.04")}]
             })
  end

  ## El listado cuenta y enlaza -------------------------------------------

  test "the list row counts its keys and links to the model page", %{conn: conn} do
    model = create_model(%{name: "listado-lane-#{unique()}"})
    provider = create_provider()
    _lane = create_lane(model, provider)
    _lane2 = create_lane(model, provider)

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    assert has_element?(
             view,
             "a#model-keys-#{model.id}[href='/catalog/models/#{model.id}']",
             "2"
           )
  end

  ## Pools de API keys ------------------------------------------------------

  test "a pool lane renders the pool name, its key count and its members", %{conn: conn} do
    model = create_model()
    provider = create_provider()

    pool = create_pool(provider, %{name: "Pool Principal"})
    c1 = create_credential(provider)
    c2 = create_credential(provider)
    m1 = add_member(pool, c1)
    m2 = add_member(pool, c2)

    {:ok, lane} =
      Providers.create_model_provider(%{
        model_id: model.id,
        pool_id: pool.id,
        provider_model: "upstream/pool-principal",
        priority: 3,
        enabled: true
      })

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    # La fila es la del LANE (misma identidad que una fila de key) y muestra el
    # pool, su conteo y la prioridad/modelo del lane.
    row = element(view, "#model-provider-#{lane.id}") |> render()
    assert row =~ "Pool Principal"
    assert has_element?(view, "#pool-member-count-#{lane.id}", "2 key(s)")
    assert row =~ "upstream/pool-principal"
    assert row =~ "3"
    # El proveedor del pool se resuelve por sus miembros.
    assert has_element?(view, "#ap-provider-#{lane.id}", provider.name)

    # El panel arranca cerrado y se abre con el toggle.
    refute has_element?(view, "#pool-members-#{lane.id}")
    view |> element("#pool-members-toggle-#{lane.id}") |> render_click()

    assert has_element?(view, "#pool-members-#{lane.id}")
    assert has_element?(view, "#pool-member-#{m1.id}", c1.name)
    assert has_element?(view, "#pool-member-#{m2.id}", c2.name)
    assert has_element?(view, "#pool-member-#{m1.id}", "••••••abcd")
  end

  test "assigning a lane from a NEW pool creates the pool and its members", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    c1 = create_credential(provider)
    c2 = create_credential(provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    pick_provider(view, provider)
    switch_to_pool(view)

    assert has_element?(view, "#lane-pool-select")
    refute has_element?(view, "#new-pool-name")

    view |> element("#new-pool-toggle") |> render_click()
    assert has_element?(view, "#new-pool-name")
    assert has_element?(view, "#new-pool-member-#{c1.id}")
    assert has_element?(view, "#new-pool-member-#{c2.id}")

    html =
      view
      |> form("#model-provider-form",
        model_provider: %{
          source: "pool",
          new_pool_name: "Pool del alta",
          new_pool_member_ids: [c1.id, c2.id],
          provider_model: "upstream/nuevo-pool",
          priority: "1"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor asignado al modelo."

    # El lane quedó montado en un pool REAL, con membresía en DB y sin credencial
    # propia.
    [lane] = Providers.list_model_providers(model.id)
    assert lane.credential_id == nil
    assert is_binary(lane.pool_id)
    assert lane.provider_model == "upstream/nuevo-pool"

    pool = Providers.get_pool!(lane.pool_id)
    assert pool.name == "Pool del alta"
    assert pool.provider_id == provider.id

    member_ids = Providers.list_pool_members(pool) |> Enum.map(& &1.credential_id)
    assert Enum.sort(member_ids) == Enum.sort([c1.id, c2.id])

    # Y la fila del pool aparece con su conteo.
    assert has_element?(view, "#pool-member-count-#{lane.id}", "2 key(s)")
    assert render(view) =~ "Pool del alta"
  end

  test "a member deleted between render and submit rolls back the whole pool", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    c1 = create_credential(provider)
    c2 = create_credential(provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    pick_provider(view, provider)
    switch_to_pool(view)
    view |> element("#new-pool-toggle") |> render_click()

    # c2 estaba en el render y desaparece antes del submit: el alta tiene que
    # fallar completa, no crear un pool con la mitad de las keys elegidas.
    {:ok, _} = Providers.delete_credential(c2)

    html =
      view
      |> form("#model-provider-form",
        model_provider: %{
          source: "pool",
          new_pool_name: "Pool Parcial",
          new_pool_member_ids: [c1.id, c2.id],
          provider_model: "upstream/parcial"
        }
      )
      |> render_submit()

    # El alta es atómica: ni pool a medias ni lane.
    assert html =~ "no sirve para este pool"
    assert Providers.list_pools_for_provider(provider.id) == []
    assert Providers.list_model_providers(model.id) == []
  end

  test "assigning a lane from an EXISTING pool keeps its members untouched", %{conn: conn} do
    model = create_model()
    provider = create_provider()

    pool = create_pool(provider, %{name: "Pool Existente"})
    c1 = create_credential(provider)
    c2 = create_credential(provider)
    add_member(pool, c1)
    add_member(pool, c2)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    pick_provider(view, provider)
    switch_to_pool(view)

    # El select ofrece los pools del proveedor.
    assert has_element?(
             view,
             "#lane-pool-select option[value='#{pool.id}']",
             "Pool Existente (2 key(s))"
           )

    html =
      view
      |> form("#model-provider-form",
        model_provider: %{
          source: "pool",
          pool_id: pool.id,
          provider_model: "upstream/pool-existente",
          priority: "2"
        }
      )
      |> render_submit()

    assert html =~ "Proveedor asignado al modelo."

    [lane] = Providers.list_model_providers(model.id)
    assert lane.pool_id == pool.id
    assert lane.credential_id == nil
    assert length(Providers.list_pool_members(pool)) == 2
  end

  test "a new pool without keys is rejected and nothing is written", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    _c1 = create_credential(provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    pick_provider(view, provider)
    switch_to_pool(view)
    view |> element("#new-pool-toggle") |> render_click()

    html =
      view
      |> form("#model-provider-form",
        model_provider: %{
          source: "pool",
          new_pool_name: "Pool vacío",
          provider_model: "upstream/pool-vacio"
        }
      )
      |> render_submit()

    # El error se ve en el modal (donde está el bloque del pool) y no se perdió
    # lo escrito.
    assert has_element?(
             view,
             "#lane-pool-error",
             "Selecciona al menos una API key para el pool nuevo."
           )

    assert has_element?(view, "#new-pool-name[value='Pool vacío']")
    refute html =~ "Proveedor asignado al modelo."

    assert Providers.list_model_providers(model.id) == []
    assert Providers.list_pools_for_provider(provider.id) == []
  end

  test "adding and removing members of a mounted pool", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool, member: member} = create_pool_lane(model, provider)

    # Segunda key del MISMO proveedor, todavía fuera del pool.
    extra = create_credential(provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#pool-members-toggle-#{lane.id}") |> render_click()

    # El select del alta ofrece sólo las keys del proveedor que NO están dentro.
    assert has_element?(view, "#pool-add-member-#{lane.id} option[value='#{extra.id}']")

    refute has_element?(
             view,
             "#pool-add-member-#{lane.id} option[value='#{member.credential_id}']"
           )

    html =
      view
      |> form("#pool-add-form-#{lane.id}", lane_id: lane.id, credential_id: extra.id)
      |> render_submit()

    assert html =~ "API key agregada al pool."
    assert Providers.list_pool_members(pool) |> length() == 2

    html = view |> element("#remove-pool-member-#{member.id}") |> render_click()
    assert html =~ "API key quitada del pool."
    assert Providers.list_pool_members(pool) |> Enum.map(& &1.credential_id) == [extra.id]

    # El panel sigue abierto tras el load_lanes.
    assert has_element?(view, "#pool-members-#{lane.id}")
  end

  test "the last member of a pool cannot be removed", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool, member: member} = create_pool_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#pool-members-toggle-#{lane.id}") |> render_click()

    html = view |> element("#remove-pool-member-#{member.id}") |> render_click()

    assert html =~ "Un pool no puede quedar sin API keys. Borra el lane o el pool en su lugar."
    assert Providers.list_pool_members(pool) |> length() == 1
    assert has_element?(view, "#pool-member-#{member.id}")
  end

  test "editing a pool lane opens in pool mode and keeps its pool", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool} = create_pool_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    # Abre en modo pool, con SU pool seleccionado y sin el select de keys.
    assert has_element?(view, "#lane-source-pool[checked]")
    assert has_element?(view, "#lane-pool-select option[selected][value='#{pool.id}']")
    refute has_element?(view, "select[name='model_provider[credential_id]']")
    refute has_element?(view, "input[name='model_provider[sticky_ttl_seconds]']")

    view
    |> form("#model-provider-form",
      model_provider: %{
        source: "pool",
        pool_id: pool.id,
        provider_model: lane.provider_model,
        priority: "7"
      }
    )
    |> render_submit()

    reloaded = Providers.get_model_provider!(lane.id)
    assert reloaded.pool_id == pool.id
    assert reloaded.credential_id == nil
    assert reloaded.priority == 7
  end

  test "converting a pool lane into a key lane clears the pool", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool} = create_pool_lane(model, provider)
    free_key = create_credential(provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    view
    |> form("#model-provider-form", model_provider: %{source: "key"})
    |> render_change()

    html =
      view
      |> form("#model-provider-form",
        model_provider: %{
          source: "key",
          credential_id: free_key.id,
          provider_model: lane.provider_model,
          priority: "3"
        }
      )
      |> render_submit()

    refute html =~ "No se pudo guardar"
    reloaded = Providers.get_model_provider!(lane.id)
    assert reloaded.credential_id == free_key.id
    assert reloaded.pool_id == nil
    assert reloaded.priority == 3
    assert Providers.get_pool(pool.id) != nil
  end

  test "deleting an unmounted pool works and clears the selection", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    pool = create_pool(provider, %{name: "Pool Huérfano"})
    add_member(pool, create_credential(provider))

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    pick_provider(view, provider)
    switch_to_pool(view)

    view
    |> form("#model-provider-form", model_provider: %{source: "pool", pool_id: pool.id})
    |> render_change()

    refute has_element?(view, "#delete-selected-pool[disabled]")
    html = view |> element("#delete-selected-pool") |> render_click()

    assert html =~ "Pool eliminado."
    assert Providers.get_pool(pool.id) == nil
    refute has_element?(view, "#lane-pool-select option[value='#{pool.id}']")
  end

  test "deleting a mounted pool is blocked with a flash", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool} = create_pool_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    html = view |> element("#delete-selected-pool") |> render_click()

    assert html =~ "montado en un modelo"
    assert Providers.get_pool(pool.id) != nil
  end

  test "deleting a pool lane removes the lane but keeps the pool", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    %{lane: lane, pool: pool} = create_pool_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    html = view |> element("#delete-ap-#{lane.id}") |> render_click()

    assert html =~ "Proveedor eliminado del modelo."
    refute has_element?(view, "#model-provider-#{lane.id}")
    assert Providers.get_model_provider(lane.id) == nil
    assert Providers.get_pool(pool.id) != nil
  end

  test "a pool lane toggles and reorders like a key lane", %{conn: conn} do
    model = create_model()
    provider = create_provider()
    key_lane = create_lane(model, provider, %{priority: 1})
    %{lane: pool_lane} = create_pool_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    html = view |> element("#toggle-ap-#{pool_lane.id}") |> render_click()
    assert html =~ "Proveedor desactivado."
    refute Providers.get_model_provider!(pool_lane.id).enabled

    # El reorder escribe prioridad por id de LANE (el del pool es uno más).
    render_hook(view, "reorder_providers", %{
      "model_id" => model.id,
      "ids" => [pool_lane.id, key_lane.id]
    })

    assert Providers.get_model_provider!(pool_lane.id).priority == 1
    assert Providers.get_model_provider!(key_lane.id).priority == 2
  end

  # El checkbox de Fireworks (service_tier) se resuelve por el proveedor de la
  # credencial al abrir el modal de edición; la guarda del pool no lo puede
  # apagar para los lanes de una key.
  test "editing a lane of a Fireworks key keeps the service_tier checkbox", %{conn: conn} do
    # La key del catálogo es única: el proveedor de prueba se queda con ella.
    case Tokengate.Repo.get_by(Tokengate.Providers.Provider, key: "fireworks-ai") do
      nil -> :ok
      builtin -> Tokengate.Repo.delete!(builtin)
    end

    provider = create_provider(%{key: "fireworks-ai", name: "Fireworks local"})
    model = create_model()
    lane = create_lane(model, provider)

    conn = admin_session(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    assert has_element?(view, "input[name='model_provider[service_tier_priority]']")
  end
end
