defmodule TokengateWeb.ModelsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Providers.{CatalogModel, CatalogModelOffer}
  alias Tokengate.Repo
  alias TokengateWeb.ModelsLive
  import Ecto.Query

  defp unique, do: System.unique_integer([:positive])

  # A provider carrying a models.dev `key`, which is what an offer joins to.
  # Created as a custom on purpose: a builtin's identity (name, base_url) is
  # catalog-owned and the changeset locks it, so a test must not build one by
  # hand — `key` is all `providers_serving/1` needs.
  defp create_keyed_provider(key, attrs \\ %{}) do
    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{name: key, base_url: "http://localhost:1", key: key, source: "custom"},
          attrs
        )
      )

    provider
  end

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "model-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma los mensajes en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
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

  defp create_custom_lab(attrs) do
    u = unique()

    {:ok, lab} =
      Providers.create_custom_lab(Map.merge(%{"name" => "Lab #{u}", "key" => "lab-#{u}"}, attrs))

    lab
  end

  # El mirror de models.dev se siembra en el ARRANQUE de la app, fuera del
  # sandbox del test: en este proceso está vacío. Sembrarlo aquí (idempotente,
  # mismo camino que `catalog_test.exs`) es lo que hace determinista lo que el
  # picker ve — sin esto, el dropdown de proveedores y la lista del catálogo
  # salen vacíos y los tests no probarían nada.
  defp seed_mirror! do
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()
    :ok
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
    view |> element("#pick-type-llm") |> render_click()
    view |> element("#wizard-all-models") |> render_click()

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

  # The type picked at step 0 IS the persisted model_type now: a service
  # model (stt) saves with its real type, not collapsed to "llm".
  test "admin creates a service model with its real type", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    # Step 0: the type picker, not the form
    assert has_element?(view, "#model-type-picker")
    refute has_element?(view, "#model-form")
    view |> element("#pick-type-stt") |> render_click()
    view |> element("#wizard-all-models") |> render_click()

    assert has_element?(view, "#model-form")

    view
    |> form("#model-form", %{
      model: %{
        name: "whisper-test",
        context_window: 128_000
      }
    })
    |> render_submit()

    model_record = Tokengate.Providers.get_model_by_name("whisper-test")
    assert model_record.model_type == "stt"
  end

  # A decision model (Jev / System One) has its OWN type in the picker — not
  # "llm (chat)" — and picking it filters the catalog down to decision models.
  test "decision type is offered and filters the catalog to Jev", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # Jev is a CODE-owned model (models.dev does not publish it): the test DB
    # only has it after the code-model sync runs.
    Tokengate.Providers.ModelCatalog.ensure_code_models()

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    assert has_element?(view, "#pick-type-decision")

    view |> element("#pick-type-decision") |> render_click()
    view |> element("#wizard-all-models") |> render_click()
    assert has_element?(view, "#model-form")

    # The catalog list behind the picker only carries decision models: search
    # for jev and it is there.
    view |> element("#catalog-search") |> render_change(%{"q" => "jev"})
    assert has_element?(view, "#catalog-row-#{ModelsLive.dom_key("typesafe/jev")}")
  end

  # El paso 1 del wizard es lo que acota el catálogo: elegido el proveedor, la
  # lista del paso 2 sólo trae sus modelos (combinado con el tipo del paso 0).
  test "el wizard acota el catálogo al proveedor elegido", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    Tokengate.Providers.ModelCatalog.ensure_code_models()
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-decision") |> render_click()

    # Paso 1: TypeSafe es el único que declara `decision`.
    view |> element("#wizard-provider-typesafe") |> render_click()

    # Paso 2: el catálogo queda acotado a ese proveedor — sólo Jev.
    html = render(view)
    assert html =~ "typesafe/jev"
    assert html =~ "TypeSafe"
  end

  # El dropdown de proveedores del picker se acota por el tipo elegido: un
  # proveedor que no declara la capability no puede servir el modelo, así que
  # ofrecerlo es un callejón sin salida.
  test "el dropdown de proveedores del picker se acota por tipo (image)", %{conn: conn} do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    # image: OpenRouter y Alibaba la declaran; Fireworks NO.
    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-image") |> render_click()

    assert has_element?(view, "#wizard-provider-openrouter")
    refute has_element?(view, "#wizard-provider-fireworks-ai")
  end

  test "el dropdown de proveedores del picker se acota por tipo (llm)", %{conn: conn} do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    # llm: Fireworks sí la declara.
    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-llm") |> render_click()

    assert has_element?(view, "#wizard-provider-fireworks-ai")
  end

  # El render del logo era `img si logo_url / icono si nil`, así que una URL que
  # responde 404 NO caía al icono: dejaba el chip VACÍO, y desde fuera se leía
  # como «a este proveedor le falta el logo». Es justo lo que pasaba con
  # qwen-cloud (PNG de alicdn muerto) y typesafe (favicon inexistente).
  # Ahora el icono va SIEMPRE en el markup (oculto sólo si hay logo) y el <img>
  # lleva `data-logo` para que el listener global de `error` (app.js) sepa cuál
  # falló y lo sustituya por el icono.
  test "con logo, la fila del wizard marca el img y deja el icono oculto de reserva", %{
    conn: conn
  } do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-llm") |> render_click()

    # openrouter sí trae logo del catálogo: img marcado + icono presente y oculto.
    assert has_element?(view, "#wizard-provider-openrouter img[data-logo]")
    assert has_element?(view, "#wizard-provider-openrouter .hero-server-stack.hidden")
  end

  test "sin logo, la fila del wizard pinta el icono visible y ningún img", %{conn: conn} do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-decision") |> render_click()

    # typesafe se queda SIN logo a propósito (su web no expone ningún asset
    # usable): icono visible, sin img y sin la clase `hidden`.
    refute has_element?(view, "#wizard-provider-typesafe img[data-logo]")
    assert has_element?(view, "#wizard-provider-typesafe .hero-server-stack")
    refute has_element?(view, "#wizard-provider-typesafe .hero-server-stack.hidden")
  end

  # Regresión del bug reportado: elegir un tipo de SERVICIO mostraba el catálogo
  # entero de models.dev (~3000 modelos de chat) en vez de nada, porque la
  # cláusula del filtro por tipo era `do: models` para todo lo que no fuera
  # llm/embedding/decision.
  test "un tipo de servicio NO lista el catálogo de chat (regresión)", %{conn: conn} do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-stt") |> render_click()
    view |> element("#wizard-all-models") |> render_click()

    # Un modelo de chat real del mirror: bajo "Transcription" no debe aparecer.
    view |> element("#catalog-search") |> render_change(%{"q" => "gpt-5"})

    refute has_element?(view, "#catalog-results")
    assert has_element?(view, "#catalog-empty")

    # El badge del tab dice la verdad: 0 modelos de este tipo en models.dev.
    assert view |> element("#tab-catalog") |> render() =~ ">0<"
  end

  # Y el mismo buscador SÍ trae el catálogo cuando el tipo lo tiene.
  test "un tipo de catálogo (llm) sí lista sus modelos", %{conn: conn} do
    seed_mirror!()
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-llm") |> render_click()
    view |> element("#wizard-all-models") |> render_click()
    view |> element("#catalog-search") |> render_change(%{"q" => "gpt-5"})

    assert has_element?(view, "#catalog-results")
    refute has_element?(view, "#catalog-empty")
  end

  # El paso 2 combina DOS fuentes: la semilla (instantánea) y el listado EN VIVO
  # del proveedor. El resultado llega por mensaje porque es una llamada HTTP.
  test "el paso 2 une el listado en vivo con la semilla", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    seed_mirror!()

    # El proveedor real apuntando a un puerto muerto: el listado en vivo falla
    # rápido y sin red, que es justo lo que este test quiere (la semilla manda).
    provider =
      Tokengate.Providers.Provider
      |> Repo.get_by(key: "openrouter")
      |> Ecto.Changeset.change(base_url: "http://localhost:1")
      |> Repo.update!()

    {:ok, _credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "live",
        api_key_encrypted: "sk-live",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-image") |> render_click()
    view |> element("#wizard-provider-openrouter") |> render_click()

    # La semilla está desde el primer render (no se espera a la red).
    assert has_element?(view, "#wizard-model-#{ModelsLive.dom_key("openai/gpt-image-2")}")

    # Y cuando llega el catálogo del proveedor, se UNE a la semilla.
    send(
      view.pid,
      {:wizard_service_models, "openrouter", "image",
       {:ok, ["nuevo/proveedor-modelo-1", "otro/proveedor-modelo-2"]}}
    )

    html = render(view)

    assert html =~ "nuevo/proveedor-modelo-1"
    assert html =~ "otro/proveedor-modelo-2"
    # La semilla NO se pierde: es unión, no reemplazo.
    assert html =~ "black-forest-labs/flux.2-pro"
  end

  # Una respuesta tardía del proveedor anterior no debe pisar la lista del
  # proveedor que el operador acaba de elegir.
  test "el listado en vivo obsoleto se descarta", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-image") |> render_click()
    view |> element("#wizard-all-models") |> render_click()

    send(
      view.pid,
      {:wizard_service_models, "openrouter", "image", {:ok, ["no/deberia-aparecer"]}}
    )

    html = render(view)
    refute html =~ "no/deberia-aparecer"
  end

  # Jev (TypeSafe) es el caso donde el precio de LISTA del catálogo es lo ÚNICO
  # que cobra: la API de TypeSafe NO reporta `usage.cost`, así que si el wizard no
  # volcara ese precio al lane, el modelo quedaría en $0 para siempre.
  test "el wizard copia el precio de lista al lane (caso Jev)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # Jev es un modelo CODE-OWNED (models.dev no lo publica): existe tras el sync.
    Tokengate.Providers.ModelCatalog.ensure_code_models()
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()

    provider = Repo.get_by(Tokengate.Providers.Provider, key: "typesafe")
    assert provider, "el sync debía materializar typesafe"

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "jev",
        api_key_encrypted: "sk-jev",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-decision") |> render_click()
    view |> element("#wizard-provider-typesafe") |> render_click()

    jev = ModelsLive.dom_key("typesafe/jev")
    assert has_element?(view, "#catalog-row-#{jev}")
    view |> element("#catalog-row-#{jev}") |> render_click()

    view
    |> element("#wizard-credential")
    |> render_change(%{"credential_id" => credential.id})

    name = "jev-wizard-#{unique()}"

    view
    |> form("#model-form", %{model: %{name: name, context_window: 64_000}})
    |> render_submit()

    model = Providers.get_model_by_name(name)
    assert model.model_type == "decision"

    ap =
      Repo.one(from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model.id)

    assert ap != nil, "el wizard debía crear el lane de Jev"
    assert ap.provider_model == "jev-latest"
    # El precio de lista del catálogo: $0.042 por millón de input, output gratis.
    assert Decimal.equal?(ap.input_cost_per_million, Decimal.new("0.042"))
    assert Decimal.equal?(ap.output_cost_per_million, Decimal.new("0"))
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

  test "key rows show Priority and pin badges from extra_body", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    model_record = create_model()

    # One row with the premium serving path, one with an aggregator pin.
    create_model_provider(model_record, provider, %{
      extra_body: %{"service_tier" => "priority"}
    })

    create_model_provider(model_record, provider, %{
      extra_body: %{"provider" => "zai"}
    })

    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/catalog/models")

    # The provider table lives inside the model's collapsible card, but the
    # rows are in the rendered DOM regardless (the collapse is client-side).
    # The UI locale is es, so badge labels render translated — assert on
    # non-translatable markers: the raw pin value and the badge icons.
    assert html =~ "hero-map-pin"
    assert html =~ "zai"
    assert html =~ "hero-bolt"
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

  # La unidad de precio la decide el TIPO del modelo: un lane de imagen no se
  # cobra por tokens, así que el modal abre en «por imagen» y ofrece `unit_cost`
  # en vez de los tres campos por millón — que sin unidad quedaban en $0 salvo
  # que el upstream reportara el coste.
  test "el modal de proveedor abre con la unidad del tipo del modelo (image)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    image_model = create_model(%{model_type: "image"})

    {:ok, _credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-ap-#{image_model.id}") |> render_click()

    assert has_element?(view, "#ap-pricing-unit option[value=\"per_image\"]")
    assert view |> element("#ap-pricing-unit") |> render() =~ "selected"

    assert has_element?(view, "#model_provider_unit_cost")
    refute has_element?(view, "#model_provider_input_cost_per_million")
  end

  test "el modal de proveedor ofrece tokens cuando el modelo es de chat", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    chat_model = create_model(%{model_type: "llm"})

    {:ok, _credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-ap-#{chat_model.id}") |> render_click()

    assert has_element?(view, "#ap-pricing-unit option[value=\"per_1m_tokens\"]")
    assert has_element?(view, "#model_provider_input_cost_per_million")
    assert has_element?(view, "#model_provider_output_cost_per_million")
    refute has_element?(view, "#model_provider_unit_cost")
  end

  test "cambiar la unidad conmuta los campos de precio", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    chat_model = create_model(%{model_type: "llm"})

    {:ok, _credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-ap-#{chat_model.id}") |> render_click()

    # Por defecto: tokens.
    assert has_element?(view, "#model_provider_input_cost_per_million")

    view
    |> element("#ap-pricing-unit")
    |> render_change(%{"model_provider" => %{"pricing_unit" => "per_request"}})

    assert has_element?(view, "#model_provider_unit_cost")
    refute has_element?(view, "#model_provider_input_cost_per_million")
    refute has_element?(view, "#model_provider_output_cost_per_million")
  end

  test "el lane guarda su unidad y su precio por unidad", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider()
    image_model = create_model(%{model_type: "image"})

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-test",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-ap-#{image_model.id}") |> render_click()

    view
    |> form("#model-provider-form", %{
      model_provider: %{
        credential_id: credential.id,
        provider_model: "gpt-image-2",
        priority: 1,
        enabled: true,
        pricing_unit: "per_image",
        unit_cost: "0.0400"
      }
    })
    |> render_submit()

    ap =
      Repo.one(
        from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^image_model.id
      )

    assert ap.pricing_unit == "per_image"
    assert Decimal.equal?(ap.unit_cost, Decimal.new("0.0400"))
  end

  # El wizard crea el modelo Y su primer lane en una sola pasada: elegido el
  # proveedor (paso 1) y el modelo de servicio (paso 2), la credencial (paso 3)
  # es lo único que falta. Sin esto el operador tendría que volver a la fila
  # recién creada y abrir el modal de asignar proveedor acto seguido.
  test "el wizard crea el modelo Y su primer lane de una vez", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # OpenRouter sale de la materialización del catálogo (declara `image` en
    # código), así que se siembra el mirror en vez de inventar un custom.
    seed_mirror!()
    provider = Repo.get_by(Tokengate.Providers.Provider, key: "openrouter")
    assert provider, "el sync debía materializar openrouter"

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "img",
        api_key_encrypted: "sk-wizard",
        status: "active"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-image") |> render_click()

    # Paso 1: el proveedor que declara el tipo.
    view |> element("#wizard-provider-openrouter") |> render_click()

    # Paso 2: los modelos de servicio curados de ese proveedor.
    nano = ModelsLive.dom_key("openai/gpt-image-2")
    assert has_element?(view, "#wizard-model-#{nano}")
    view |> element("#wizard-model-#{nano}") |> render_click()

    # Paso 3: la credencial, que es el input necesario para que el modelo rutee.
    view |> element("#wizard-credential") |> render_change(%{"credential_id" => credential.id})

    name = "gpt-image-wizard-#{unique()}"

    view
    |> form("#model-form", %{model: %{name: name, context_window: 32_768}})
    |> render_submit()

    model = Providers.get_model_by_name(name)
    assert model.model_type == "image"

    ap =
      Repo.one(from mp in Tokengate.Providers.ModelProvider, where: mp.model_id == ^model.id)

    assert ap != nil, "el wizard debía crear el lane junto con el modelo"
    assert ap.credential_id == credential.id
    assert ap.provider_model == "openai/gpt-image-2"
    # El lane nace con la unidad del TIPO del modelo, no en tokens.
    assert ap.pricing_unit == "per_image"
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

    test "shows the service_tier checkbox and the automatic-cache note for fireworks", %{
      conn: conn
    } do
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
      # The automatic prompt-cache note is visible.
      assert render(view) =~ "activa por defecto"
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

  # -- Model catalog picker --------------------------------------------------

  # A catalog row, exactly as the refresh writes one.
  defp create_catalog_model(key, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base = %{
      key: key,
      name: attrs[:name] || key,
      lab_key: attrs[:lab_key],
      description: attrs[:description] || "Una descripción",
      canonical: attrs[:canonical] || false,
      context_limit: attrs[:context_limit] || 128_000,
      output_limit: 8_192,
      cost_input: attrs[:cost_input],
      cost_output: attrs[:cost_output],
      cost_cache_read: attrs[:cost_cache_read],
      cost_cache_write: nil,
      modalities: %{},
      features: attrs[:features] || [],
      release_date: nil,
      last_updated: nil,
      license: nil,
      status: "active",
      fetched_at: now,
      entered_at: now
    }

    %CatalogModel{}
    |> Ecto.Changeset.change(Map.drop(base, [:entered_at]))
    |> Repo.insert!()
  end

  defp create_offer(provider_key, model_key, attrs \\ %{}) do
    %CatalogModelOffer{}
    |> Ecto.Changeset.change(%{
      provider_key: provider_key,
      model_key: model_key,
      provider_model: attrs[:provider_model] || model_key,
      cost_input: attrs[:cost_input],
      cost_output: attrs[:cost_output],
      tiers: [],
      lifecycle: "stable",
      experimental: false,
      status: "active"
    })
    |> Repo.insert!()
  end

  describe "model catalog picker" do
    # The picker reads the mirror it finds in the database. The boot seed fills
    # it with the whole vendored catalog (~3120 rows), which would push these
    # fixtures past the picker's first page: isolate them.
    setup do
      Repo.delete_all(Tokengate.Providers.CatalogModelOffer)
      Repo.delete_all(Tokengate.Providers.CatalogModel)
      :ok
    end

    test "creating a model offers the catalog first and a custom tab", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")

      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      assert has_element?(view, "#model-form")
      assert has_element?(view, "#tab-catalog")
      assert has_element?(view, "#tab-custom")
      # El buscador necesita un form ancestro: sin él el phx-change muere en el
      # navegador (LiveViewTest lo despacharía igual, así que se aspira el anidado).
      assert has_element?(view, "form#catalog-search-form input#catalog-search")
      # The picker is the default tab: a new model starts from the catalog.
      assert has_element?(view, "#catalog-picker")

      # The custom tab hides the picker but keeps the form (nothing is lost).
      view |> element("#tab-custom") |> render_click()
      refute has_element?(view, "#catalog-picker")
      assert has_element?(view, "#model-form")
    end

    # Regresión: escribir el nombre con el ícono vacío crasheaba el render (la
    # vista previa le pasaba `name: ""` a `<.icon>`), mataba el proceso y el
    # navegador reconectaba con el modal «reiniciado».
    test "typing on the custom tab with a blank icon keeps the modal alive", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")

      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()
      view |> element("#tab-custom") |> render_click()

      html =
        view
        |> form("#model-form", %{"model" => %{"name" => "mi-modelo"}})
        |> render_change()

      assert has_element?(view, "#model-form")
      assert has_element?(view, "#model_name[value='mi-modelo']")
      assert html =~ "mi-modelo"
    end

    test "searching narrows the catalog and picking fills the form", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      _ =
        create_catalog_model("openai/gpt-5-nano",
          name: "GPT-5 Nano",
          lab_key: "openai",
          context_limit: 400_000
        )

      _ = create_catalog_model("zai/glm-5.2", name: "GLM-5.2", lab_key: "zai")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      # Every catalog row is filterable in memory. The DOM id is derived from
      # the key with `dom_key/1` (keys carrying `/` get a hash suffix), so the
      # test builds the selector the same way instead of hardcoding it.
      nano_id = "catalog-row-" <> ModelsLive.dom_key("openai/gpt-5-nano")
      glm_id = "catalog-row-" <> ModelsLive.dom_key("zai/glm-5.2")

      assert has_element?(view, "##{nano_id}")

      view |> element("#catalog-search") |> render_change(%{"q" => "glm"})

      assert has_element?(view, "##{glm_id}")
      refute has_element?(view, "##{nano_id}")

      # Picking prefills the operator's form with the catalog metadata.
      view |> element("##{glm_id}") |> render_click()

      assert has_element?(view, "#catalog-linked")
      html = render(view)
      assert html =~ "zai/glm-5.2"
      assert html =~ ~s(value="glm-5.2")
    end

    test "picking a catalog row prefills the form", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      _ =
        create_catalog_model("openai/gpt-5-nano",
          name: "GPT-5 Nano",
          lab_key: "openai"
        )

      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      view
      |> element("#catalog-row-#{ModelsLive.dom_key("openai/gpt-5-nano")}")
      |> render_click()

      # El catálogo prellena lo que define al modelo (nombre corto, ventana de
      # contexto y el vínculo de vuelta); nada queda bloqueado.
      assert has_element?(view, "#model_name[value='gpt-5-nano']")
      assert has_element?(view, "#model_context_window[value='128000']")
      assert has_element?(view, "#catalog-linked")
    end

    test "a search with no match points at the custom tab", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _ = create_catalog_model("openai/gpt-5-nano")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      view |> element("#catalog-search") |> render_change(%{"q" => "no-existe-xyz"})

      assert has_element?(view, "#catalog-empty")
      refute has_element?(view, "#catalog-results")
    end

    test "saving a picked model stores the catalog link and the lab", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      _ =
        create_catalog_model("openai/gpt-5-nano",
          name: "GPT-5 Nano",
          lab_key: "openai",
          context_limit: 400_000,
          cost_input: Decimal.new("0.045")
        )

      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()
      view |> element("#catalog-row-#{ModelsLive.dom_key("openai/gpt-5-nano")}") |> render_click()

      view
      |> form("#model-form", %{
        "model" => %{"name" => "gpt-5-nano-cat", "context_window" => "400000"}
      })
      |> render_submit()

      saved = Providers.get_model_by_name("gpt-5-nano-cat")
      assert saved.catalog_model_key == "openai/gpt-5-nano"
      assert saved.lab_key == "openai"
    end

    test "an already-registered catalog entry is flagged in the picker", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _ = create_catalog_model("openai/gpt-5-nano", name: "GPT-5 Nano")

      _existing =
        create_model(%{name: "ya-existe", catalog_model_key: "openai/gpt-5-nano"})

      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      html =
        view |> element("#catalog-row-#{ModelsLive.dom_key("openai/gpt-5-nano")}") |> render()

      assert html =~ "ya existe"
    end

    test "editar ofrece el mismo picker y re-vincula sin crear otra fila", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      _ =
        create_catalog_model("openai/gpt-5-nano",
          name: "GPT-5 Nano",
          lab_key: "openai",
          context_limit: 400_000
        )

      # Una fila a mano: no nació del catálogo, así que no tiene vínculo.
      model_record = create_model(%{name: "a-mano-#{unique()}"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#edit-model-#{model_record.id}") |> render_click()

      # Mismo picker que al crear: pestañas, buscador y listado al teclear.
      assert has_element?(view, "#model-form-tabs")
      assert has_element?(view, "#tab-catalog")
      assert has_element?(view, "#catalog-picker")
      assert has_element?(view, "form#catalog-search-form input#catalog-search")
      assert has_element?(view, "#catalog-hint")
      refute has_element?(view, "#catalog-linked")

      view |> element("#catalog-search") |> render_change(%{"q" => "gpt-5-nano"})

      row = "catalog-row-#{ModelsLive.dom_key("openai/gpt-5-nano")}"
      assert has_element?(view, "##{row}")

      view |> element("##{row}") |> render_click()

      # El vínculo se refleja antes de guardar.
      assert has_element?(view, "#catalog-linked")

      relinked = "re-vinculado-#{unique()}"

      view
      |> form("#model-form", %{"model" => %{"name" => relinked}})
      |> render_submit()

      saved = Providers.get_model_by_name(relinked)

      # Es la MISMA fila —rellenar no puede convertir el update en un insert— y
      # el vínculo con el catálogo (con su lab) quedó guardado.
      assert saved.id == model_record.id
      assert saved.catalog_model_key == "openai/gpt-5-nano"
      assert saved.lab_key == "openai"
      assert saved.context_window == 400_000
    end
  end

  # -- Marca del modelo (lab + icono) ---------------------------------------

  describe "marca del modelo" do
    test "con lab vinculado la marca es la del lab y no se ofrece icono propio", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      lab = create_custom_lab(%{"name" => "Mi Lab", "icon" => "hero-fire"})
      model_record = create_model(%{lab_key: lab.key})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")

      # La card del listado ya lleva la marca del lab.
      assert has_element?(view, "#model-mark-#{model_record.id} .hero-fire")

      view |> element("#edit-model-#{model_record.id}") |> render_click()

      assert has_element?(view, "#model-mark-preview-inner .hero-fire")
      assert has_element?(view, "#model-mark-origin", "Marca del lab Mi Lab.")
      # Con un lab vinculado el icono propio queda en espera: no hay picker.
      refute has_element?(view, "#model-icon-picker")
    end

    test "sin lab la marca es el icono genérico y la paleta fija uno propio", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      assert has_element?(view, "#model-icon-picker")
      assert has_element?(view, "#model-mark-preview-inner .hero-cpu-chip")
      assert has_element?(view, "#model-mark-origin", "Icono genérico")

      view |> element("#model-icon-choice-hero-bolt") |> render_click()
      assert has_element?(view, "#model-mark-preview-inner .hero-bolt")
      assert has_element?(view, "#model-mark-origin", "Icono propio del modelo.")

      view
      |> form("#model-form", %{
        model: %{name: "marca-propia", context_window: 128_000}
      })
      |> render_submit()

      saved = Tokengate.Providers.get_model_by_name("marca-propia")
      assert saved.icon == "hero-bolt"
      # Y la card del listado la reusa.
      assert has_element?(view, "#model-mark-#{saved.id} .hero-bolt")
    end

    test "un lab_key sin fila en labs se sigue ofreciendo en el select", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      model_record = create_model(%{lab_key: "lab-fantasma", icon: "hero-rocket-launch"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#edit-model-#{model_record.id}") |> render_click()

      # Si el select no pudiera representarlo, guardar borraría el vínculo.
      assert has_element?(view, "#model-form option[value='lab-fantasma']")
      # Un vínculo sin fila no da marca: manda el icono propio del modelo.
      assert has_element?(view, "#model-mark-preview-inner .hero-rocket-launch")
      assert has_element?(view, "#model-icon-picker")
    end
  end

  # -- The picker against the REAL, seeded mirror ----------------------------

  # No setup clearing the mirror on purpose: these run against the vendored
  # catalog (~3120 models) a fresh instance seeds. The isolated tests above prove
  # the behaviour; this proves the SIZE does not break it.
  describe "model catalog picker (real mirror)" do
    # The boot task that seeds the mirror runs OUTSIDE the Ecto sandbox, so the
    # test database may hold nothing. Seed it here, from the vendored snapshot:
    # that is what a fresh instance would have.
    setup do
      Tokengate.Providers.CatalogSeed.seed_models_if_empty()
      :ok
    end

    test "the picker renders and searches the mirror the database actually holds", %{conn: conn} do
      # The isolated tests above prove the BEHAVIOUR; this one proves the SIZE
      # does not break it. It deliberately does NOT clear the mirror: it runs
      # against the real vendored catalog (~3120 models) that a fresh instance
      # seeds, which is the case a hand-made fixture cannot catch.
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-model-btn") |> render_click()
      view |> element("#pick-type-llm") |> render_click()
      view |> element("#wizard-all-models") |> render_click()

      # The modal opens with the whole catalog loaded in memory.
      assert has_element?(view, "#catalog-picker")
      assert has_element?(view, "#catalog-search")

      # The first page is filled from the real mirror (whatever its size).
      assert has_element?(view, "#catalog-results")
      assert render(view) =~ "catalog-row-"

      # A search over thousands of rows stays a render, not a crash.
      view |> element("#catalog-search") |> render_change(%{"q" => "gpt-5-nano"})

      assert has_element?(view, "#catalog-results")
      html = render(view)
      assert html =~ "Mostrando"

      # And a term nobody publishes answers with the empty state.
      view |> element("#catalog-search") |> render_change(%{"q" => "zzz-no-existe-zzz"})
      assert has_element?(view, "#catalog-empty")
    end
  end

  # -- Provider + API key in one modal ---------------------------------------

  describe "provider then API key" do
    # The picker reads the mirror it finds in the database. The boot seed fills
    # it with the whole vendored catalog (~3120 rows), which would push these
    # fixtures past the picker's first page: isolate them.
    setup do
      Repo.delete_all(Tokengate.Providers.CatalogModelOffer)
      Repo.delete_all(Tokengate.Providers.CatalogModel)
      :ok
    end

    test "the provider picker lists only what serves the model, cheapest first", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      cheap = create_keyed_provider("cheap-cloud", %{name: "Cheap Cloud"})
      pricey = create_keyed_provider("pricey-cloud", %{name: "Pricey Cloud"})
      _other = create_keyed_provider("unrelated", %{name: "Unrelated"})

      _ = create_catalog_model("openai/gpt-5-nano", name: "GPT-5 Nano")
      _ = create_offer("pricey-cloud", "openai/gpt-5-nano", cost_input: Decimal.new("9.0"))
      _ = create_offer("cheap-cloud", "openai/gpt-5-nano", cost_input: Decimal.new("0.5"))

      model_record =
        create_model(%{name: "nano", catalog_model_key: "openai/gpt-5-nano"})

      assert cheap.id && pricey.id
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      assert has_element?(view, "#provider-results")
      assert has_element?(view, "#provider-row-cheap-cloud")
      assert has_element?(view, "#provider-row-pricey-cloud")
      # A provider with no offer for this model is not offered at all.
      refute has_element?(view, "#provider-row-unrelated")

      html = render(view)
      assert order_before?(html, "cheap-cloud", "pricey-cloud")
    end

    test "picking a provider narrows the credentials and prefills the model id", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})
      other = create_keyed_provider("beta", %{name: "Beta Cloud"})

      {:ok, alpha_cred} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "Alpha key",
          api_key_encrypted: "sk-alpha-1234",
          status: "active"
        })

      {:ok, _beta_cred} =
        Providers.create_credential(%{
          provider_id: other.id,
          name: "Beta key",
          api_key_encrypted: "sk-beta-1234",
          status: "active"
        })

      _ = create_catalog_model("openai/gpt-5-nano")
      _ = create_offer("alpha", "openai/gpt-5-nano", cost_input: Decimal.new("0.5"))

      model_record = create_model(%{name: "nano2", catalog_model_key: "openai/gpt-5-nano"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()
      view |> element("#provider-row-alpha") |> render_click()

      assert has_element?(view, "#selected-provider")

      # The credential select holds only THIS provider's keys, and the provider's
      # own model id came from the offer.
      html = render(view)
      assert html =~ "Alpha key"
      refute html =~ "Beta key"
      assert html =~ "openai/gpt-5-nano"

      # The one existing key is preselected: nothing to choose.
      assert has_element?(
               view,
               "select[name='model_provider[credential_id]'] option[value='#{alpha_cred.id}'][selected]"
             )
    end

    test "picking the API key derives its provider and fills the list price", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})

      {:ok, cred} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "Alpha key",
          api_key_encrypted: "sk-alpha-1111",
          status: "active"
        })

      _ = create_catalog_model("openai/gpt-5-nano")

      _ =
        create_offer("alpha", "openai/gpt-5-nano",
          cost_input: Decimal.new("0.5"),
          cost_output: Decimal.new("2.0")
        )

      model_record = create_model(%{name: "nano-key", catalog_model_key: "openai/gpt-5-nano"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      # Nothing picked yet: no provider chip, and the key list is open.
      refute has_element?(view, "#selected-provider")

      # Choosing ONLY the key resolves the provider (no provider click).
      view
      |> form("#model-provider-form", %{model_provider: %{credential_id: cred.id}})
      |> render_change()

      assert has_element?(view, "#selected-provider")
      assert render(view) =~ "Alpha Cloud"

      # The offer for that provider+model preloaded the provider model id and
      # the list prices.
      assert has_element?(
               view,
               "input[name='model_provider[provider_model]'][value='openai/gpt-5-nano']"
             )

      # El input guarda el Decimal con la escala de la columna ("0.500000").
      assert has_element?(
               view,
               "input[name='model_provider[input_cost_per_million]'][value^='0.5']"
             )

      assert has_element?(
               view,
               "input[name='model_provider[output_cost_per_million]'][value^='2.0']"
             )
    end

    test "an operator-typed provider model survives picking the API key", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})

      {:ok, cred} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "Alpha key",
          api_key_encrypted: "sk-alpha-3333",
          status: "active"
        })

      _ = create_catalog_model("openai/gpt-5-nano")
      _ = create_offer("alpha", "openai/gpt-5-nano", cost_input: Decimal.new("0.5"))

      model_record = create_model(%{name: "nano-typed", catalog_model_key: "openai/gpt-5-nano"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      typed = %{
        provider_model: "mi-tier-dedicado",
        priority: 7
      }

      view
      |> form("#model-provider-form", %{model_provider: typed})
      |> render_change()

      # Picking the key re-renders the form: what the operator already typed
      # (and phx-change just submitted) must survive the offer defaults.
      view
      |> form("#model-provider-form", %{model_provider: Map.put(typed, :credential_id, cred.id)})
      |> render_change()

      assert has_element?(
               view,
               "input[name='model_provider[provider_model]'][value='mi-tier-dedicado']"
             )

      assert has_element?(view, "input[name='model_provider[priority]'][value='7']")

      # Only the still-empty field takes the offer.
      assert has_element?(
               view,
               "input[name='model_provider[input_cost_per_million]'][value^='0.5']"
             )
    end

    test "a key from a provider that does not serve the model derives the provider only", %{
      conn: conn
    } do
      %{user: admin, password: password} = register("admin")

      # "unrelated" publishes no offer for the catalog model.
      provider = create_keyed_provider("unrelated", %{name: "Unrelated Cloud"})

      {:ok, cred} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "Unrelated key",
          api_key_encrypted: "sk-unrelated-1111",
          status: "active"
        })

      _ = create_catalog_model("openai/gpt-5-nano")
      model_record = create_model(%{name: "nano-other", catalog_model_key: "openai/gpt-5-nano"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      view
      |> form("#model-provider-form", %{model_provider: %{credential_id: cred.id}})
      |> render_change()

      # The provider is known (the key names it) even though it has no offer.
      assert has_element?(view, "#selected-provider")
      html = render(view)
      assert html =~ "Unrelated Cloud"

      # No offer: nothing to fill.
      refute has_element?(
               view,
               "input[name='model_provider[provider_model]'][value='openai/gpt-5-nano']"
             )

      refute has_element?(
               view,
               "input[name='model_provider[input_cost_per_million]'][value^='0.5']"
             )
    end

    test "editing a row whose provider is identified fills the empty list price", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})

      {:ok, cred} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "Alpha key",
          api_key_encrypted: "sk-alpha-2222",
          status: "active"
        })

      _ = create_catalog_model("openai/gpt-5-nano")
      _ = create_offer("alpha", "openai/gpt-5-nano", cost_input: Decimal.new("0.7"))

      model_record = create_model(%{name: "nano-edit", catalog_model_key: "openai/gpt-5-nano"})

      # Stored row with no manual price: the modal fills it from models.dev.
      {:ok, mp} =
        Providers.create_model_provider(%{
          model_id: model_record.id,
          credential_id: cred.id,
          provider_model: "openai/gpt-5-nano",
          priority: 1,
          enabled: true
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#edit-ap-#{mp.id}") |> render_click()

      assert has_element?(
               view,
               "input[name='model_provider[input_cost_per_million]'][value^='0.7']"
             )

      # An operator-set price still wins over the offer.
      {:ok, _} =
        Providers.update_model_provider(mp, %{input_cost_per_million: Decimal.new("9.5")})

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#edit-ap-#{mp.id}") |> render_click()

      assert has_element?(
               view,
               "input[name='model_provider[input_cost_per_million]'][value^='9.5']"
             )
    end

    test "a provider with no key can get one without leaving the modal", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})
      _ = create_catalog_model("openai/gpt-5-nano")
      _ = create_offer("alpha", "openai/gpt-5-nano")
      model_record = create_model(%{name: "nano3", catalog_model_key: "openai/gpt-5-nano"})

      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()
      view |> element("#provider-row-alpha") |> render_click()

      assert has_element?(view, "#no-credentials-hint")

      view |> element("#new-credential-inline") |> render_click()
      assert has_element?(view, "#inline-credential-form")
      assert has_element?(view, "#inline-credential")

      view
      |> form("#inline-credential", %{
        "credential" => %{
          "name" => "Primera key",
          "api_key_encrypted" => "sk-brand-new-0001"
        }
      })
      |> render_submit()

      # Created, and left selected: the model is one click from routable.
      [credential] = Providers.list_credentials_for_provider(provider.id)
      assert credential.name == "Primera key"
      refute has_element?(view, "#no-credentials-hint")

      assert has_element?(
               view,
               "select[name='model_provider[credential_id]'] option[value='#{credential.id}'][selected]"
             )
    end

    test "the whole flow creates a routable model_provider", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      provider = create_keyed_provider("alpha", %{name: "Alpha Cloud"})
      _ = create_catalog_model("openai/gpt-5-nano")
      _ = create_offer("alpha", "openai/gpt-5-nano", cost_input: Decimal.new("0.5"))

      model_record = create_model(%{name: "nano4", catalog_model_key: "openai/gpt-5-nano"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()
      view |> element("#provider-row-alpha") |> render_click()
      view |> element("#new-credential-inline") |> render_click()

      view
      |> form("#inline-credential", %{
        "credential" => %{"name" => "Prod", "api_key_encrypted" => "sk-prod-9999"}
      })
      |> render_submit()

      view
      |> form("#model-provider-form", %{
        "model_provider" => %{"provider_model" => "openai/gpt-5-nano", "enabled" => "true"}
      })
      |> render_submit()

      [mp] = Providers.list_model_providers(model_record.id)
      assert mp.provider_model == "openai/gpt-5-nano"
      assert mp.credential.provider_id == provider.id
      assert mp.enabled == true
    end

    test "a custom model keeps every active provider to choose from", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _ = create_keyed_provider("alpha", %{name: "Alpha Cloud"})
      _ = create_keyed_provider("beta", %{name: "Beta Cloud"})

      # No catalog link: nothing to narrow by, so the whole active list is
      # offered. The search box is how the operator reaches the one they want.
      model_record = create_model(%{name: "by-hand"})
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/catalog/models")
      view |> element("#new-ap-#{model_record.id}") |> render_click()

      assert has_element?(view, "#provider-search")

      view |> element("#provider-search") |> render_change(%{"q" => "Alpha"})
      assert has_element?(view, "#provider-row-alpha")

      view |> element("#provider-search") |> render_change(%{"q" => "Beta"})
      assert has_element?(view, "#provider-row-beta")
    end
  end
end
