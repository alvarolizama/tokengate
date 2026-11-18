defmodule TokengateWeb.ModelsLiveModalsTest do
  @moduledoc """
  Regresión de los dos modales de `/catalog/models` — el wizard de alta de modelo
  y el modal de lane/API key. Un test por hallazgo del run (`P1..P11`), taggeado
  por la fase que lo arregla para que el gate de cada fase filtre por él:

    * `modal_group: "wizard"` — W1: crashes y pérdidas del wizard
    * `modal_group: "lane"` — W2: estado del modal de lane
    * `modal_group: "credentials"` — W3: credenciales no activas y TTL sticky

  Sin red: los upstreams apuntan a `http://localhost:1` (falla rápido) o a
  `http://192.0.2.1:81` (no contesta, deja el fetch en vuelo a propósito).
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Providers.ModelProvider
  alias TokengateWeb.ModelsLive

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "modals-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Los tests afirman el texto en español: el idioma por defecto de la UI es
    # inglés, así que el usuario arranca en español (misma receta que
    # `models_live_test.exs`).
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp create_provider(attrs) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(%{name: "Provider #{u}", base_url: "http://localhost:1"}, attrs)
      )

    provider
  end

  # Un proveedor con `key` de catálogo (lo que resuelve capabilities y dialecto)
  # sobre un upstream muerto: el listado falla rápido y sin red.
  defp create_keyed_provider(key, attrs) do
    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{name: key, base_url: "http://localhost:1", key: key, source: "custom"},
          attrs
        )
      )

    provider
  end

  defp create_credential(provider, attrs \\ %{}) do
    u = unique()

    {:ok, credential} =
      Providers.create_credential(
        Map.merge(
          %{
            provider_id: provider.id,
            name: "key-#{u}",
            api_key_encrypted: "sk-#{u}",
            status: "active"
          },
          attrs
        )
      )

    credential
  end

  defp create_model(attrs) do
    u = unique()

    {:ok, model_record} =
      Providers.create_model(
        Map.merge(%{name: "model-#{u}", context_window: 128_000, pinned: true}, attrs)
      )

    model_record
  end

  defp create_model_provider(model_id, credential_id, attrs) do
    {:ok, ap} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_id: model_id,
            credential_id: credential_id,
            provider_model: "pm-#{unique()}",
            priority: 1,
            enabled: true
          },
          attrs
        )
      )

    ap
  end

  defp lanes_of(model_id) do
    Repo.all(from mp in ModelProvider, where: mp.model_id == ^model_id)
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_wizard(conn, type \\ "llm") do
    {:ok, view, _html} = live(conn, ~p"/catalog/models")
    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-#{type}") |> render_click()
    view
  end

  defp form_tag(html, id) do
    Regex.run(~r/<form[^>]*id="#{id}"[^>]*>/, html) |> hd()
  end

  # El mirror de models.dev se siembra en el ARRANQUE de la app, fuera del
  # sandbox del test: aquí se siembra a mano (idempotente) para que el catálogo
  # de capabilities sea determinista.
  defp seed_mirror! do
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()
    :ok
  end

  # Un proveedor del catálogo (materializado por la semilla) apuntado a un
  # upstream muerto: su listado falla rápido, sin red.
  defp dead_provider!(key) do
    seed_mirror!()

    Tokengate.Providers.Provider
    |> Repo.get_by!(key: key)
    |> Ecto.Changeset.change(base_url: "http://localhost:1")
    |> Repo.update!()
  end

  # ===========================================================================
  # W1 — crashes y pérdidas del wizard (modal_group: "wizard")
  # ===========================================================================

  # P1 — `wizard_back` acepta cualquier paso: los tres botones que mandan
  # `step="credential"` mueven de paso en vez de matar el LiveView.
  @tag modal_group: "wizard"
  test "P1 los tres botones Atrás/Cambiar vuelven al paso de la key sin matar el wizard", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    provider = create_keyed_provider("acme-p1", %{name: "Acme P1"})
    _cred = create_credential(provider)
    conn = login(conn, admin, password)

    view = open_wizard(conn)
    view |> element("#wizard-provider-acme-p1") |> render_click()

    # Back del paso "model" (phx-value-step="credential").
    view |> element("#wizard-continue") |> render_click()
    view |> element("#wizard-back-to-credential") |> render_click()
    assert has_element?(view, "#wizard-credential-form")

    # Change de la key desde el paso "model", mismo step.
    view |> element("#wizard-continue") |> render_click()
    view |> element("#wizard-change-key-from-models") |> render_click()
    assert has_element?(view, "#wizard-credential-form")

    # Change de la key desde el paso de datos, mismo step.
    view |> element("#wizard-continue") |> render_click()
    view |> element("#wizard-write-by-hand") |> render_click()
    view |> element("#wizard-change-key") |> render_click()
    assert has_element?(view, "#wizard-credential-form")

    assert Process.alive?(view.pid)
  end

  # P2 — un alta que no puede crear el lane lo dice con flash de error y nombra
  # el motivo; nunca anuncia un alta completa cuando no hay asignación.
  @tag modal_group: "wizard"
  test "P2 el alta sin lane muestra error con el motivo y no 'Modelo creado'", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    with_key = create_keyed_provider("acme-p2", %{name: "Acme P2"})
    _cred = create_credential(with_key)
    _without_key = create_keyed_provider("acme-p2b", %{name: "Acme P2b"})
    conn = login(conn, admin, password)

    # (a) Proveedor con key, id del modelo tecleado y borrado: el lane no se
    # puede crear (provider_model vacío).
    view = open_wizard(conn)
    view |> element("#wizard-provider-acme-p2") |> render_click()
    view |> element("#wizard-continue") |> render_click()
    view |> element("#wizard-write-by-hand") |> render_click()

    view
    |> element("#wizard-provider-model-form")
    |> render_change(%{"wizard_provider_model" => "acme/x"})

    view
    |> element("#wizard-provider-model-form")
    |> render_change(%{"wizard_provider_model" => ""})

    empty_id = "sin-id-#{unique()}"

    html =
      view
      |> form("#model-form", %{model: %{name: empty_id, context_window: 32_768}})
      |> render_submit()

    model = Providers.get_model_by_name(empty_id)

    assert model
    assert lanes_of(model.id) == []
    assert html =~ "sin asignación de proveedor"
    assert html =~ "el id del modelo en el proveedor está vacío"
    refute html =~ "Modelo creado"

    # (b) Proveedor sin ninguna key: el lane tampoco puede existir y el motivo
    # es la key, no el id.
    view |> element("#new-model-btn") |> render_click()
    view |> element("#pick-type-llm") |> render_click()
    view |> element("#wizard-provider-acme-p2b") |> render_click()
    view |> element("#wizard-continue") |> render_click()
    assert has_element?(view, "#wizard-models-need-key")
    view |> element("#wizard-write-by-hand") |> render_click()

    view
    |> element("#wizard-provider-model-form")
    |> render_change(%{"wizard_provider_model" => "acme/manual"})

    no_key = "sin-key-#{unique()}"

    html =
      view
      |> form("#model-form", %{model: %{name: no_key, context_window: 32_768}})
      |> render_submit()

    model = Providers.get_model_by_name(no_key)

    assert model
    assert lanes_of(model.id) == []
    assert html =~ "sin asignación de proveedor"
    assert html =~ "no se seleccionó ninguna API key"
    refute html =~ "Modelo creado"
  end

  # P8 — Enter en los dos campos del wizard no recarga: los `<form>` internos
  # resuelven el submit en el servidor (phx-submit) en vez de en un GET nativo.
  @tag modal_group: "wizard"
  test "P8 el id y el select de key resuelven Enter en el servidor", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_keyed_provider("acme-p8", %{name: "Acme P8"})
    _cred = create_credential(provider)
    conn = login(conn, admin, password)

    view = open_wizard(conn)
    view |> element("#wizard-provider-acme-p8") |> render_click()

    credential_form = form_tag(render(view), "wizard-credential-form")
    assert credential_form =~ "phx-change"
    assert credential_form =~ "phx-submit"

    view |> element("#wizard-continue") |> render_click()
    view |> element("#wizard-write-by-hand") |> render_click()

    provider_model_form = form_tag(render(view), "wizard-provider-model-form")
    assert provider_model_form =~ "phx-change"
    assert provider_model_form =~ "phx-submit"

    # Y el submit de verdad no se lleva el wizard: el paso sigue abierto y el
    # valor tecleado llega al servidor.
    view
    |> form("#wizard-provider-model-form", %{wizard_provider_model: "acme/typed"})
    |> render_submit()

    assert has_element?(view, "#model-form")
    assert lv_assigns(view).wizard_provider_model == "acme/typed"
  end

  # P9 — el error/spinner del listado de una alta no se hereda a la siguiente.
  @tag modal_group: "wizard"
  test "P9 el error del listado no aparece en la siguiente alta", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    with_key = create_keyed_provider("acme-p9", %{name: "Acme P9"})
    credential = create_credential(with_key)
    _without_key = create_keyed_provider("acme-p9b", %{name: "Acme P9b"})
    conn = login(conn, admin, password)

    view = open_wizard(conn)
    view |> element("#wizard-provider-acme-p9") |> render_click()

    view
    |> element("#wizard-credential-form")
    |> render_change(%{"credential_id" => credential.id})

    view |> element("#wizard-continue") |> render_click()

    send(
      view.pid,
      {:wizard_models_result, "acme-p9", "llm", credential.id, {:error, :connection_error}}
    )

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#wizard-models-error")

    # Otra alta: atrás hasta el picker de tipo y de ahí a un proveedor SIN key.
    view |> element("#wizard-back-to-credential") |> render_click()
    view |> element("#wizard-back-to-provider") |> render_click()
    view |> element("#wizard-back-to-type") |> render_click()
    view |> element("#pick-type-llm") |> render_click()
    view |> element("#wizard-provider-acme-p9b") |> render_click()
    view |> element("#wizard-continue") |> render_click()

    refute has_element?(view, "#wizard-models-error")
    refute has_element?(view, "#wizard-models-loading")
    assert has_element?(view, "#wizard-models-need-key")
  end

  # ===========================================================================
  # W2 — estado del modal de lane (modal_group: "lane")
  # ===========================================================================

  # P4 — el picker del modal de lane filtra por el tipo del MODELO destino, no
  # por el tipo que quedó pegado del último alta del wizard.
  @tag modal_group: "lane"
  test "P4 el tipo del wizard no acota el picker de un modelo llm", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # Fireworks declara llm/embedding/decision: sirve un modelo llm y NO uno de
    # imagen — es el proveedor que el filtro del wizard escondía.
    fireworks = dead_provider!("fireworks-ai")
    _cred = create_credential(fireworks)
    llm_model = create_model(%{name: "llm-p4-#{unique()}", model_type: "llm"})

    conn = login(conn, admin, password)
    # El alta del modelo vive en el listado; el modal de lane, en la página del
    # modelo. El test cruza las dos pantallas, así que monta las dos vistas.
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{llm_model.id}")
    {:ok, index, _html} = live(recycle(conn), ~p"/catalog/models")

    # A) Antes del wizard, el picker del lane ofrece Fireworks.
    view |> element("#new-ap-#{llm_model.id}") |> render_click()
    view |> element("#provider-search") |> render_change(%{"q" => "fireworks"})
    assert has_element?(view, "#provider-row-#{ModelsLive.dom_key(fireworks.key)}")
    render_click(view, "cancel_model_provider", %{})

    # B) El operador crea un modelo de IMAGEN con el wizard (en el listado).
    index |> element("#new-model-btn") |> render_click()
    index |> element("#pick-type-image") |> render_click()
    index |> element("#wizard-custom") |> render_click()

    image_html =
      index
      |> form("#model-form", %{model: %{name: "img-p4-#{unique()}", context_window: 4_000}})
      |> render_submit()

    assert image_html =~ "Modelo creado"
    assert lv_assigns(index).model_form_picked_type == "image"

    # C) Mismo modal de lane, mismo modelo llm: Fireworks sigue en el picker.
    view |> element("#new-ap-#{llm_model.id}") |> render_click()

    assert Enum.any?(
             lv_assigns(view).provider_choices,
             &(&1.provider.id == fireworks.id)
           )

    view |> element("#provider-search") |> render_change(%{"q" => "fireworks"})
    assert has_element?(view, "#provider-row-#{ModelsLive.dom_key(fireworks.key)}")
  end

  # P5 — el spinner sólo existe mientras hay un fetch en vuelo: al abrir, al
  # pulsar "Change" y al cerrar por guardado el flag está apagado.
  @tag modal_group: "lane"
  test "P5 el spinner no sobrevive a ninguna transición del modal", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    # Upstream que no contesta: el fetch se queda en vuelo y el flag en true.
    hanging = create_provider(%{name: "Hang P5", base_url: "http://192.0.2.1:81"})
    credential = create_credential(hanging)
    m1 = create_model(%{name: "m1-p5-#{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{m1.id}")

    # Abrir: no hay fetch en vuelo.
    view |> element("#new-ap-#{m1.id}") |> render_click()
    refute lv_assigns(view).provider_models_loading
    refute render(view) =~ "Cargando models del proveedor"

    # Elegir el proveedor: ahora SÍ hay uno.
    view |> element("#provider-search") |> render_change(%{"q" => hanging.name})
    view |> element("#provider-row-#{ModelsLive.dom_key(hanging.id)}") |> render_click()
    assert lv_assigns(view).provider_models_loading

    # "Change" descarta el proveedor y con él el fetch que quedaba colgado.
    view |> element("#change-provider") |> render_click()
    refute lv_assigns(view).provider_models_loading
    refute render(view) =~ "Cargando models del proveedor"

    # Guardar cierra el modal: el flag no puede quedar encendido.
    view |> element("#provider-search") |> render_change(%{"q" => hanging.name})
    view |> element("#provider-row-#{ModelsLive.dom_key(hanging.id)}") |> render_click()
    assert lv_assigns(view).provider_models_loading

    html =
      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "pm-p5",
          priority: 2,
          enabled: true
        }
      })
      |> render_submit()

    assert html =~ "Proveedor asignado"
    refute lv_assigns(view).provider_models_loading

    # Y el modal siguiente arranca limpio.
    view |> element("#new-ap-#{m1.id}") |> render_click()
    refute lv_assigns(view).provider_models_loading
  end

  # P7 — "Change" limpia la key y el catálogo: la respuesta tardía del proveedor
  # descartado ya no pasa el guard ni pinta nada.
  @tag modal_group: "lane"
  test "P7 Change limpia la credencial y el catálogo del proveedor descartado", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    hanging = create_provider(%{name: "Hang P7", base_url: "http://192.0.2.1:81"})
    credential = create_credential(hanging)
    model = create_model(%{name: "m-p7-#{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    view |> element("#provider-search") |> render_change(%{"q" => hanging.name})
    view |> element("#provider-row-#{ModelsLive.dom_key(hanging.id)}") |> render_click()

    view |> element("#change-provider") |> render_click()

    assigns = lv_assigns(view)

    assert assigns.provider_form_credential_id == nil
    assert assigns.provider_models == []
    refute has_element?(view, "#selected-provider")
    # El select ya no lleva la key del proveedor descartado.
    assert assigns.provider_form[:credential_id].value in [nil, ""]

    # La respuesta tardía del proveedor descartado no pinta su catálogo.
    send(
      view.pid,
      {:provider_models_result, credential.id, {:ok, ["modelo-del-proveedor-viejo"]}}
    )

    html = render(view)

    refute html =~ "modelo-del-proveedor-viejo"
  end

  # P10 — la respuesta del listado no borra el filtro que el operador tecleó en
  # `provider_model`.
  @tag modal_group: "lane"
  test "P10 el resultado async conserva el filtro de sugerencias", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    # Upstream que no contesta: el único resultado que llega es el que manda el
    # test, así que el orden es determinista.
    hanging = create_provider(%{name: "Hang P10", base_url: "http://192.0.2.1:81"})
    credential = create_credential(hanging)
    model = create_model(%{name: "m-p10-#{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()
    view |> element("#provider-search") |> render_change(%{"q" => hanging.name})
    view |> element("#provider-row-#{ModelsLive.dom_key(hanging.id)}") |> render_click()

    send(view.pid, {:provider_models_result, credential.id, {:ok, ["alpha-model", "beta-model"]}})
    html = render(view)
    assert html =~ "alpha-model"
    assert html =~ "beta-model"

    # El operador filtra tecleando en provider_model.
    view
    |> form("#model-provider-form", %{
      model_provider: %{credential_id: credential.id, provider_model: "alpha"}
    })
    |> render_change()

    html = render(view)
    assert html =~ "alpha-model"
    refute html =~ "beta-model"

    # Llega otro resultado del proveedor con el filtro puesto.
    send(view.pid, {:provider_models_result, credential.id, {:ok, ["alpha-model", "beta-model"]}})
    html = render(view)

    assert lv_assigns(view).provider_model_search == "alpha"
    assert html =~ "alpha-model"
    refute html =~ "beta-model"
  end

  # P11 — "New API key" resuelve el proveedor por la credencial elegida: si el
  # chip lo muestra, la key inline se puede crear.
  @tag modal_group: "lane"
  test "P11 la API key inline acepta el proveedor que el chip muestra", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    # Proveedor fuera del picker (no está `active`) pero con una key activa: su
    # credencial SÍ entra en el select, así que la key fija el proveedor.
    provider = create_provider(%{name: "Disabled P11", status: "disabled"})
    credential = create_credential(provider)
    model = create_model(%{name: "m-p11-#{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()

    view
    |> form("#model-provider-form", %{model_provider: %{credential_id: credential.id}})
    |> render_change()

    assert has_element?(view, "#selected-provider")

    html = view |> element("#new-credential-inline") |> render_click()

    assert has_element?(view, "#inline-credential-form")
    refute html =~ "Elige primero el proveedor"
  end

  # P12 — el wizard de alta vive en el contenedor único (`.modal`): overlay +
  # card con cierre en `cancel_form` (✕/Escape/click-away) y el indicador de
  # pasos lo pinta `.steps` como `<id>-steps`, una miga por paso y la activa
  # siguiendo el assign `wizard_step` (current_step). En edición no hay pasos:
  # `steps` va nil y el indicador no aparece.
  @tag modal_group: "wizard"
  test "P12 el wizard de alta usa el contenedor .modal y el indicador .steps", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_keyed_provider("acme-p12", %{name: "Acme P12"})
    _cred = create_credential(provider)
    model = create_model(%{name: "m-p12-#{unique()}"})
    conn = login(conn, admin, password)

    view = open_wizard(conn)

    # Contenedor `.modal`: fijo, con el mismo closer en ✕/Escape/click-away.
    assert has_element?(
             view,
             ~s|#model-wizard.fixed.inset-0[phx-window-keydown="cancel_form"]|
           )

    assert has_element?(view, "#model-wizard .relative.card")

    # Indicador `.steps`: id derivado del modal y una miga por paso.
    assert has_element?(view, "#model-wizard-steps")

    for step <- ~w(provider credential model details) do
      assert has_element?(view, "#wizard-crumb-#{step}")
    end

    # La miga activa sale de `@wizard_step` (no hay estado en el componente).
    assert has_element?(view, "#wizard-crumb-provider.border-primary")
    refute has_element?(view, "#wizard-crumb-credential.border-primary")

    view |> element("#wizard-provider-acme-p12") |> render_click()

    assert has_element?(view, "#wizard-crumb-credential.border-primary")
    refute has_element?(view, "#wizard-crumb-provider.border-primary")

    # Edición: entra directa a los datos, sin migas.
    {:ok, edit_view, _html} = live(conn, ~p"/catalog/models")
    edit_view |> element("#edit-model-#{model.id}") |> render_click()

    assert has_element?(edit_view, "#model-wizard")
    assert has_element?(edit_view, "#model-form")
    refute has_element?(edit_view, "#model-wizard-steps")
  end

  # ===========================================================================
  # W3 — credenciales no activas y TTL sticky (modal_group: "credentials")
  # ===========================================================================

  # P3 — vaciar el TTL sticky del modal lo deja en NULL (default de config) en
  # la DB, no lo resucita desde el valor guardado.
  @tag modal_group: "credentials"
  test "P3 vaciar el TTL sticky lo borra de la DB", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider(%{name: "Ttl P3"})
    credential = create_credential(provider)
    model = create_model(%{name: "m-p3-#{unique()}"})

    ap =
      create_model_provider(model.id, credential.id, %{
        provider_model: "pm-ttl",
        sticky_ttl_ms: 900_000
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#edit-ap-#{ap.id}") |> render_click()

    # El form pinta los segundos que corresponden al valor guardado.
    assert lv_assigns(view).provider_form[:sticky_ttl_seconds].value == 900

    html =
      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "pm-ttl",
          priority: 1,
          enabled: true,
          sticky_ttl_seconds: ""
        }
      })
      |> render_submit()

    assert html =~ "Proveedor actualizado"
    assert Providers.get_model_provider!(ap.id).sticky_ttl_ms == nil
  end

  # P6 — editar un lane cuya key quedó en `error` conserva y muestra su
  # proveedor y su key, y deja guardar prioridad/precio sin cambiar de key.
  @tag modal_group: "credentials"
  test "P6 editar un lane con la key en error conserva proveedor y key", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    provider = create_provider(%{name: "Keyless P6"})
    credential = create_credential(provider, %{name: "vieja"})
    model = create_model(%{name: "m-p6-#{unique()}"})

    ap = create_model_provider(model.id, credential.id, %{provider_model: "pm-x", priority: 1})

    # Un 401 del upstream deja la key fuera de `active`.
    {:ok, _} = Providers.update_credential(credential, %{status: "error"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#edit-ap-#{ap.id}") |> render_click()

    assigns = lv_assigns(view)

    assert assigns.provider_form_credential_id == credential.id
    assert has_element?(view, "#selected-provider")
    # La key de la fila se puede representar en el select (no "no hay keys").
    assert Enum.any?(assigns.credential_choices, &(&1.id == credential.id))

    html =
      view
      |> form("#model-provider-form", %{
        model_provider: %{
          credential_id: credential.id,
          provider_model: "pm-x",
          priority: 5,
          enabled: true
        }
      })
      |> render_submit()

    assert html =~ "Proveedor actualizado"

    updated = Providers.get_model_provider!(ap.id)

    assert updated.priority == 5
    assert updated.credential_id == credential.id
  end
end
