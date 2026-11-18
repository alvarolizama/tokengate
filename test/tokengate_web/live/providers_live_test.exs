defmodule TokengateWeb.ProvidersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Providers.ProviderPaths

  defp unique, do: System.unique_integer([:positive])

  # The catalog mirror is seeded at boot (outside the test sandbox, and it can
  # be cut short), so make it deterministic here: the add-provider modal reads
  # the mirror, not the vendored snapshot.
  setup do
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()
    :ok
  end

  defp register_admin do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "admin-#{u}@example.com",
        name: "Admin #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    # Este archivo afirma los mensajes en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el admin arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

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

    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  # La lista de proveedores ya no tiene tabs: se monta una vez y el render
  # trae la lista entera (builtin primero, custom al final).
  defp live_providers(conn) do
    live(conn, ~p"/catalog/providers")
  end

  # Wizard del alta/edición: los dos pasos del formulario viven siempre en el
  # DOM (para que Save envíe todos los campos), así que el paso activo se
  # afirma por la pill resaltada de `.steps` y por la clase `hidden` del bloque
  # inactivo — lo que el operador ve, no lo que el HTML conserva.
  defp active_step(view) do
    Enum.filter(~w(pick identity limits), fn step ->
      has_element?(view, "#wizard-crumb-#{step}.border-primary")
    end)
  end

  defp hidden_step?(view, step), do: has_element?(view, "#provider-step-#{step}.hidden")

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

  # The form derives its VALUES from Catalog.capabilities/0 and labels them in
  # a literal case: a capability added to the catalog without a label would
  # silently vanish from the form. This guard turns that drift into a failure.
  test "capability_choices covers the full catalog vocabulary, in order" do
    assert Enum.map(TokengateWeb.ProvidersLive.capability_choices(), &elem(&1, 1)) ==
             Tokengate.Providers.Catalog.capabilities()
  end

  ## Permissions -----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/catalog/providers")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/catalog/providers")
  end

  test "admin sees the provider list with a created provider", %{conn: conn} do
    u = unique()
    provider = create_provider(%{name: "listed-prov-#{u}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live_providers(conn)

    assert html =~ "Proveedores"
    assert has_element?(view, "#providers-#{provider.id}")
    refute has_element?(view, "#providers-empty")
  end

  # La lista es una TABLA: una fila por proveedor, y las API keys se gestionan
  # en su propia página (/catalog/providers/:id/keys), no embebidas por fila.
  test "la lista de proveedores es una tabla con una fila por proveedor", %{conn: conn} do
    provider = create_provider(%{name: "table-prov-#{unique()}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    assert has_element?(view, "tbody#providers")
    assert has_element?(view, "tbody#providers tr#providers-#{provider.id}")

    # Ya no hay grid de cards ni panel de credenciales dentro de la fila.
    refute has_element?(view, "#providers.grid")
    refute has_element?(view, "#credentials-panel-#{provider.id}")
    refute has_element?(view, "#credential-form")
  end

  # El chip del logo es claro a propósito: los logos de models.dev usan
  # fill="currentColor" y dentro de un <img> eso resuelve a negro — sobre el
  # card oscuro (tema dim) quedaban invisibles. Un proveedor sin logo del
  # catálogo (los customs) cae al icono genérico, oscuro sobre ese chip.
  test "el chip del logo: claro para el catálogo, genérico para los sin logo", %{conn: conn} do
    with_logo = create_provider(%{logo_url: "https://models.dev/logos/openrouter.svg"})
    without_logo = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    assert has_element?(
             view,
             "#providers-#{with_logo.id} span.bg-white img[src='https://models.dev/logos/openrouter.svg']"
           )

    assert has_element?(
             view,
             "#providers-#{without_logo.id} span.bg-white span.hero-server-stack.text-neutral-600"
           )
  end

  test "una sola lista sin tabs: builtin primero y custom al final", %{conn: conn} do
    u = unique()

    # Un builtin visible (los builtin solo salen con credencial) y un custom.
    {:ok, builtin} =
      %Providers.Provider{}
      |> Ecto.Changeset.change(
        key: "catalog-prov-#{u}",
        name: "Zzz Builtin #{u}",
        base_url: "https://catalog-#{u}.example.com/v1",
        source: "builtin",
        dialect: "openai",
        capabilities: ["llm"],
        status: "active"
      )
      |> Tokengate.Repo.insert()

    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: builtin.id,
        name: "Producción",
        api_key_encrypted: "***",
        status: "active"
      })

    # El custom se llama «Aaa…» a propósito: alfabéticamente iría ANTES que el
    # builtin «Zzz…», así que si el orden dependiera del nombre esta aserción
    # fallaría. Va al final por ser custom.
    custom = create_provider(%{name: "Aaa Custom #{u}"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, html} = live_providers(conn)

    refute has_element?(view, "#providers-tabs")

    {builtin_at, _} = :binary.match(html, ~s(id="providers-#{builtin.id}"))
    {custom_at, _} = :binary.match(html, ~s(id="providers-#{custom.id}"))

    assert builtin_at < custom_at
  end

  ## Provider CRUD ---------------------------------------------------------

  test "admin creates a provider", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    # The entry point is the wizard, and it opens on the catalog pick step: the
    # searchable picker is step 1 of the same modal, not a modal of its own.
    view |> element("#add-provider-btn") |> render_click()
    assert has_element?(view, "#provider-wizard-modal")
    assert has_element?(view, "#provider-wizard-modal-steps")
    assert active_step(view) == ["pick"]
    assert has_element?(view, "#catalog-results")
    assert has_element?(view, "#new-custom-provider-btn")

    # "Custom provider" advances to identity in the same modal (step 1 → 2).
    view |> element("#new-custom-provider-btn") |> render_click()
    assert has_element?(view, "#provider-wizard-modal")
    assert active_step(view) == ["identity"]
    assert has_element?(view, "#provider-form")
    refute has_element?(view, "#catalog-results")
    # The limits step exists already but is not the one on screen.
    assert hidden_step?(view, "limits")
    refute has_element?(view, "#save-provider-btn")

    # The hidden sentinel is load-bearing: without it the browser never sends
    # an explicit empty list, and "uncheck everything" would silently no-op.
    assert has_element?(
             view,
             "#provider-form input[type='hidden'][name='provider[capabilities][]']"
           )

    # Capabilities are part of the alta now: the group offers the Catalog
    # vocabulary with the schema default (chat) pre-checked.
    assert has_element?(view, "#provider-capabilities")
    assert has_element?(view, "#provider-capabilities input[value='llm'][checked]")
    refute has_element?(view, "#provider-capabilities input[value='decision'][checked]")

    view
    |> form("#provider-form",
      provider: %{name: "anthropic", base_url: "https://api.anthropic.com/v1"}
    )
    |> render_change()

    # Valid identity → the wizard moves on to the limits.
    view |> element("#provider-next-btn") |> render_click()
    assert active_step(view) == ["limits"]
    refute hidden_step?(view, "limits")
    assert hidden_step?(view, "identity")
    assert has_element?(view, "#save-provider-btn")

    # Back keeps what was typed: the steps share one changeset.
    view |> element("#provider-back-btn") |> render_click()
    assert active_step(view) == ["identity"]
    assert has_element?(view, "#provider-form input[name='provider[name]'][value='anthropic']")

    view |> element("#provider-next-btn") |> render_click()

    # Save carries the whole form: the identity typed on step 2 still travels
    # even though only the limits are on screen.
    html =
      view
      |> form("#provider-form", provider: %{max_rpm: "120"})
      |> render_submit()

    assert html =~ "Proveedor creado."

    # A custom has no catalog entry to derive capabilities from, so what gets
    # stored is the schema default (chat).
    created = Tokengate.Repo.get_by!(Providers.Provider, name: "anthropic")
    assert created.capabilities == ["llm"]
    assert created.max_rpm == 120

    # El custom aparece en la misma lista que los builtin (ya no hay tab).
    assert render(view) =~ "anthropic"
  end

  # Validación por paso: identity no avanza con name/base_url vacíos, con una
  # URL que no es http(s) ni sin ninguna capability. El wizard se queda en el
  # paso y dice por qué; nada se persiste hasta Save.
  test "el paso identity valida antes de avanzar", %{conn: conn} do
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#add-provider-btn") |> render_click()
    view |> element("#new-custom-provider-btn") |> render_click()

    # Sin nombre ni base URL.
    view |> form("#provider-form", provider: %{name: "", base_url: ""}) |> render_change()
    view |> element("#provider-next-btn") |> render_click()

    assert active_step(view) == ["identity"]
    assert hidden_step?(view, "limits")
    assert has_element?(view, "#provider-step-error", "El nombre y la base URL son obligatorios.")

    # Base URL que no es http(s).
    view
    |> form("#provider-form", provider: %{name: "relay", base_url: "relay.example.com/v1"})
    |> render_change()

    view |> element("#provider-next-btn") |> render_click()

    assert active_step(view) == ["identity"]

    assert has_element?(
             view,
             "#provider-step-error",
             "La base URL debe ser una URL http(s) válida."
           )

    # Identidad válida pero sin ninguna capability.
    view
    |> form("#provider-form",
      provider: %{
        name: "relay",
        base_url: "https://relay.example.com/v1",
        capabilities: [""]
      }
    )
    |> render_change()

    view |> element("#provider-next-btn") |> render_click()

    assert active_step(view) == ["identity"]

    assert has_element?(
             view,
             "#provider-step-error",
             "Elige al menos una capability para continuar."
           )

    refute Tokengate.Repo.get_by(Providers.Provider, name: "relay")

    # Con una capability sí avanza.
    view |> form("#provider-form", provider: %{capabilities: ["", "llm"]}) |> render_change()
    view |> element("#provider-next-btn") |> render_click()

    assert active_step(view) == ["limits"]
    refute has_element?(view, "#provider-step-error")
  end

  # En edición el wizard entra al paso relevante: un custom a identity (ahí
  # viven su nombre y su URL) y un builtin a limits sin indicador de pasos — su
  # identidad es del catálogo y lo único editable son los límites.
  test "edición: el wizard entra al paso relevante", %{conn: conn} do
    custom = create_provider(%{capabilities: ["llm", "embedding"]})

    {:ok, builtin} =
      %Providers.Provider{}
      |> Ecto.Changeset.change(
        key: "catalog-wizard-#{unique()}",
        name: "Catalog Wizard #{unique()}",
        base_url: "https://catalog-#{unique()}.example.com/v1",
        source: "builtin",
        dialect: "openai",
        capabilities: ["llm"],
        status: "active"
      )
      |> Tokengate.Repo.insert()

    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: builtin.id,
        name: "Producción",
        api_key_encrypted: "«redacted:sk-…»",
        status: "active"
      })

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    # Custom: entra por identity, con los dos pasos a la vista.
    view |> element("#edit-#{custom.id}") |> render_click()
    assert has_element?(view, "#provider-wizard-modal")
    assert has_element?(view, "#provider-wizard-modal-steps")
    assert active_step(view) == ["identity"]
    assert hidden_step?(view, "limits")
    # Al editar no hay paso de catálogo: el proveedor ya está elegido.
    refute has_element?(view, "#wizard-crumb-pick")
    refute has_element?(view, "#provider-back-btn")

    view |> element("#provider-next-btn") |> render_click()
    assert active_step(view) == ["limits"]
    assert has_element?(view, "#provider-back-btn")

    view |> element("#provider-back-btn") |> render_click()
    assert active_step(view) == ["identity"]

    assert has_element?(
             view,
             "#provider-form input[name='provider[name]'][value='#{custom.name}']"
           )

    view |> element("#provider-cancel-btn") |> render_click()
    refute has_element?(view, "#provider-wizard-modal")

    # Builtin: solo límites, sin pasos ni Back (no hay otro paso que ver).
    view |> element("#edit-#{builtin.id}") |> render_click()
    assert has_element?(view, "#provider-wizard-modal")
    refute has_element?(view, "#provider-wizard-modal-steps")
    refute has_element?(view, "#wizard-crumb-limits")
    refute has_element?(view, "#provider-back-btn")
    assert has_element?(view, "#save-provider-btn")
    assert has_element?(view, "#provider-form input[name='provider[name]'][disabled]")
  end

  test "editing a custom pre-checks its capabilities and can extend them", %{conn: conn} do
    provider = create_provider(%{capabilities: ["llm", "embedding", "stt"]})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#edit-#{provider.id}") |> render_click()
    assert has_element?(view, "#provider-capabilities")
    assert has_element?(view, "#provider-capabilities input[value='stt'][checked]")
    refute has_element?(view, "#provider-capabilities input[value='decision'][checked]")

    html =
      view
      |> form("#provider-form",
        provider: %{
          max_rpm: "60",
          capabilities: ["llm", "embedding", "stt", "decision"]
        }
      )
      |> render_submit()

    assert html =~ "Proveedor actualizado."

    reloaded = Providers.get_provider!(provider.id)
    assert reloaded.max_rpm == 60
    assert reloaded.capabilities == ["llm", "embedding", "stt", "decision"]
  end

  # The oMLX case: a local OpenAI-compatible server that also speaks the
  # decisions surface. Declaring the capability on the custom is what makes
  # the model wizard offer it for a decision-type model.
  test "a custom declaring decision becomes visible to the decision routing", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#add-provider-btn") |> render_click()
    view |> element("#new-custom-provider-btn") |> render_click()

    html =
      view
      |> form("#provider-form",
        provider: %{
          name: "omlx",
          base_url: "http://127.0.0.1:8000/v1",
          # The sentinel rides first, exactly as a real browser submits it.
          capabilities: ["", "llm", "decision"]
        }
      )
      |> render_submit()

    assert html =~ "Proveedor creado."

    created = Tokengate.Repo.get_by!(Providers.Provider, name: "omlx")
    assert created.capabilities == ["llm", "decision"]
    assert Providers.declares?(created, "decision")
    assert created.id in Enum.map(Providers.providers_declaring("decision"), & &1.id)
  end

  # The checkbox group carries a hidden empty sentinel: unchecking everything
  # submits an explicit empty list, and routing reads an empty set as
  # chat-only (effective_capabilities/1 never returns []).
  test "unchecking every capability stores an empty set; routing falls back to chat", %{
    conn: conn
  } do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#add-provider-btn") |> render_click()
    view |> element("#new-custom-provider-btn") |> render_click()

    html =
      view
      |> form("#provider-form",
        provider: %{
          name: "solo-chat",
          base_url: "https://relay.example.com/v1",
          capabilities: [""]
        }
      )
      |> render_submit()

    assert html =~ "Proveedor creado."

    created = Tokengate.Repo.get_by!(Providers.Provider, name: "solo-chat")
    assert created.capabilities == []
    assert Providers.declares?(created, "llm")
    refute Providers.declares?(created, "decision")
  end

  # The case with real consequence: a custom that ALREADY declares services
  # loses them all on a deliberate uncheck-everything edit.
  test "editing a custom and unchecking everything stores an empty set", %{conn: conn} do
    provider = create_provider(%{capabilities: ["llm", "embedding", "stt"]})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#edit-#{provider.id}") |> render_click()
    assert has_element?(view, "#provider-capabilities input[value='stt'][checked]")

    html =
      view
      |> form("#provider-form", provider: %{capabilities: [""]})
      |> render_submit()

    assert html =~ "Proveedor actualizado."

    reloaded = Providers.get_provider!(provider.id)
    assert reloaded.capabilities == []
    # Empty set = chat only, by the effective_capabilities fallback.
    assert Providers.declares?(reloaded, "llm")
    refute Providers.declares?(reloaded, "stt")
  end

  test "admin edits a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

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
    {:ok, view, _html} = live_providers(conn)

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
    {:ok, view, _html} = live_providers(conn)

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "está en uso por uno o más modelos"
    assert has_element?(view, "#edit-#{provider.id}")
  end

  ## API keys (own page) ---------------------------------------------------

  # La gestión de keys ya no vive aquí: cada fila de la tabla lleva a
  # /catalog/providers/:id/keys, que es donde se dan de alta y se editan.
  test "cada fila lleva a la pagina de API keys del proveedor", %{conn: conn} do
    provider = create_provider()
    empty_provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    assert has_element?(
             view,
             "a#provider-keys-#{provider.id}[href='/catalog/providers/#{provider.id}/keys']"
           )

    # La tabla cuenta las keys del proveedor, incluidas las que están en error.
    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "Producción",
        api_key_encrypted: "sk-table",
        status: "error"
      })

    {:ok, view, _html} = live_providers(recycle(conn))

    assert has_element?(
             view,
             "a#provider-keys-#{provider.id}[href='/catalog/providers/#{provider.id}/keys']",
             "1"
           )

    assert has_element?(view, "#provider-keys-#{empty_provider.id}", "0")
  end

  ## Builtin (catalog) providers ------------------------------------------------

  test "catálogo: el modal busca en el espejo y activa un proveedor", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    refute has_element?(view, "#provider-wizard-modal")
    view |> element("#add-provider-btn") |> render_click()
    assert has_element?(view, "#provider-wizard-modal")

    # The whole mirror is listed, with the custom entry point and the doc link.
    assert has_element?(view, "#catalog-row-fireworks-ai")
    assert has_element?(view, "#catalog-row-fireworks-ai a#docs-fireworks-ai")
    assert has_element?(view, "#new-custom-provider-btn")

    # El buscador vive dentro de un <form>: un `phx-change` suelto sobre un
    # input sin form revienta en el cliente ("form events require the input to
    # be inside a form") y el evento nunca llega al servidor.
    assert has_element?(view, "#catalog-search-form input#catalog-search")

    # Search filters by name and by models.dev id, and says when nothing matches.
    view |> render_change("search_catalog", %{"query" => "FIREWORKS"})
    assert has_element?(view, "#catalog-row-fireworks-ai")
    refute has_element?(view, "#catalog-row-openrouter")

    view |> render_change("search_catalog", %{"query" => "opencode"})
    assert has_element?(view, "#catalog-row-opencode")
    # `deepseek` is a separate provider: the mirror is a provider catalog, not
    # a model catalog, so no model name ever matches.
    refute has_element?(view, "#catalog-row-deepseek")

    view |> render_change("search_catalog", %{"query" => "zzz-no-existe"})
    assert has_element?(view, "#catalog-empty")
    refute has_element?(view, "#catalog-row-fireworks-ai")

    # Capabilities are code configuration, not picker chrome: neither a declared
    # set nor a "sin declarar" placeholder ever shows on a row.
    view |> render_change("search_catalog", %{"query" => "302ai"})
    assert has_element?(view, "#catalog-row-302ai")
    refute has_element?(view, "#catalog-row-302ai .badge")

    view |> render_change("search_catalog", %{"query" => "fireworks"})
    assert has_element?(view, "#catalog-row-fireworks-ai")
    refute has_element?(view, "#catalog-row-fireworks-ai .badge")
    refute render(view) =~ "sin declarar"

    # Activating a provider IS attaching its first key, and keys live on their
    # own page: the click navigates there with the alta modal already open.
    view |> render_change("search_catalog", %{"query" => "fireworks"})

    provider = Tokengate.Repo.get_by!(Providers.Provider, key: "fireworks-ai")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#activate-catalog-fireworks-ai") |> render_click()

    assert to == "/catalog/providers/#{provider.id}/keys?new=1"

    {:ok, keys_view, _html} = live(conn, to)
    assert has_element?(keys_view, "#credential-form")

    assert has_element?(
             keys_view,
             "#credential-form input[name='credential[provider_id]'][value='#{provider.id}']"
           )
  end

  test "catálogo: los recomendados encabezan el listado", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    view |> element("#add-provider-btn") |> render_click()

    # El orden de las filas es el orden de documento: los ids aparecen en el
    # HTML renderizado en ese orden.
    keys =
      Regex.scan(~r/id="catalog-row-([a-z0-9-]+)"/, render(view))
      |> Enum.map(&List.last/1)

    # OpenRouter, RunInfra y Fireworks encabezan en el orden fijado; después
    # sigue el espejo alfabético (302.AI es el primero por nombre).
    assert Enum.take(keys, 3) == ["openrouter", "runinfra", "fireworks-ai"]
    assert Enum.at(keys, 3) == "302ai"

    # Marcador de recomendado en los tres, y en ningún otro.
    for key <- ["openrouter", "runinfra", "fireworks-ai"] do
      assert has_element?(view, "#catalog-row-#{key}", "recomendado")
    end

    refute has_element?(view, "#catalog-row-302ai", "recomendado")

    # La búsqueda conserva el marcador en las filas que siguen visibles.
    render_change(view, "search_catalog", %{"query" => "fireworks"})
    assert has_element?(view, "#catalog-row-fireworks-ai", "recomendado")
  end

  test "catálogo: el buscador no lista lo que el gateway no puede servir", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    view |> element("#add-provider-btn") |> render_click()
    view |> render_change("search_catalog", %{"query" => "anthropic"})

    # Not listed at all: no base URL upstream means nothing to activate, so
    # the picker only offers rows the gateway can actually serve.
    refute has_element?(view, "#catalog-row-anthropic")
    refute render(view) =~ "no publica su base URL"
  end

  test "catálogo: un proveedor ya activo no se vuelve a activar", %{conn: conn} do
    provider =
      Tokengate.Repo.get_by!(Providers.Provider, key: "moonshotai")

    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-live",
        status: "active"
      })

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    view |> element("#add-provider-btn") |> render_click()
    view |> render_change("search_catalog", %{"query" => "moonshotai"})

    assert has_element?(view, "#catalog-row-moonshotai")
    refute has_element?(view, "#activate-catalog-moonshotai[phx-click]")
    assert render(view) =~ "activo"
  end

  test "builtin providers are editable for their limits only", %{conn: conn} do
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
    # Una sola lista: el builtin y el custom salen juntos en el mismo render.
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    # Builtin: the limits are the operator's, so the card is editable — but the
    # catalog identity inside the form stays read-only.
    assert has_element?(view, "#edit-#{builtin.id}")
    assert has_element?(view, "#providers-#{custom.id}")

    view |> element("#edit-#{builtin.id}") |> render_click()
    assert has_element?(view, "#provider-form")
    assert has_element?(view, "#provider-form input[name='provider[name]'][disabled]")
    assert has_element?(view, "#provider-form input[name='provider[base_url]'][disabled]")
    refute has_element?(view, "#provider-form input[name='provider[max_rpm]'][disabled]")
    # Capabilities are catalog-owned for builtins: the group never renders.
    refute has_element?(view, "#provider-capabilities")

    html =
      view
      |> form("#provider-form", provider: %{max_rpm: "120", receive_timeout_ms: "90000"})
      |> render_submit()

    assert html =~ "Proveedor actualizado."

    reloaded = Providers.get_provider!(builtin.id)
    assert reloaded.max_rpm == 120
    assert reloaded.receive_timeout_ms == 90_000
    # Identity untouched.
    assert reloaded.name == builtin.name
    assert reloaded.base_url == builtin.base_url
    # The group never renders for builtins (nothing to submit through the
    # form); the changeset lock against forged submits is covered in
    # ProviderTest's "identity stays locked".
    assert reloaded.capabilities == ["llm"]

    # The card shows the limits the keys below it inherit.
    limits_html = render(view)
    assert limits_html =~ "RPM 120"
    assert limits_html =~ "90000 ms"

    assert has_element?(view, "#edit-#{custom.id}")
    # Both keep the status toggle
    assert has_element?(view, "#toggle-provider-#{builtin.id}") ||
             has_element?(view, "#toggle-provider-#{custom.id}")
  end

  test "a provider with no limits shows them as unlimited and the timeout as global", %{
    conn: conn
  } do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    html = render(view)
    assert html =~ "RPM ∞"
    assert html =~ "Conc. ∞"
    assert html =~ "Conc./usuario ∞"

    assert html =~
             "#{Tokengate.Providers.ProviderLimits.default_receive_timeout_ms()} ms (global)"

    assert has_element?(view, "#provider-limits-#{provider.id}")
  end

  test "custom edit modal keeps identity fields editable", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#edit-#{provider.id}") |> render_click()

    assert has_element?(view, "#provider-form")
    refute has_element?(view, "#provider-form input[name='provider[name]'][disabled]")
    refute has_element?(view, "#provider-form input[name='provider[base_url]'][disabled]")
  end

  ## Capacidades (per-service paths) ---------------------------------------

  test "capacidades: el botón va justo a la izquierda de Editar", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    html = render(view)
    paths_at = :binary.match(html, ~s(id="paths-#{provider.id}"))

    assert paths_at != :nomatch
    assert paths_at < :binary.match(html, ~s(id="edit-#{provider.id}"))
  end

  test "capacidades: el modal lista el vocabulario y guarda solo lo escrito", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    refute has_element?(view, "#paths-modal")

    view |> element("#paths-#{provider.id}") |> render_click()
    assert has_element?(view, "#paths-modal")

    # Un solo contenedor (.modal) en toda la página: ✕ propio + Escape, y sin
    # pasos — es un formulario corto, partirlo sería sobre-ingeniería.
    assert has_element?(view, "#paths-modal button[aria-label='Cerrar']")
    assert has_element?(view, "#paths-modal[phx-window-keydown='cancel_paths']")
    refute has_element?(view, "#paths-modal-steps")

    # One input per capability, empty by default: an empty input inherits, and
    # the placeholder shows exactly what it would inherit — the generic path of
    # the service (a custom has no catalog entry).
    for service <- ProviderPaths.services() do
      assert has_element?(view, "#paths-form input[name='paths[#{service.key}]'][value='']")

      assert has_element?(
               view,
               "#paths-form input[name='paths[#{service.key}]'][placeholder='#{service.default}']"
             )
    end

    html =
      view
      |> form("#paths-form", paths: %{chat: "/v1/chat", image: "/v1/images"})
      |> render_submit()

    assert html =~ "Paths actualizados (2 overrides)."
    refute has_element?(view, "#paths-modal")

    reloaded = Providers.get_provider!(provider.id)
    assert reloaded.path_overrides == %{"chat" => "/v1/chat", "image" => "/v1/images"}

    # The card badge counts them, and reopening shows what was stored.
    assert has_element?(view, "#paths-#{provider.id}", "2")

    view |> element("#paths-#{provider.id}") |> render_click()
    assert has_element?(view, "#paths-form input[name='paths[chat]'][value='/v1/chat']")
  end

  test "capacidades: un path inválido no se guarda y el modal sigue abierto", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#paths-#{provider.id}") |> render_click()

    html =
      view
      |> form("#paths-form", paths: %{chat: "chat/completions"})
      |> render_submit()

    assert html =~ "debe empezar con /"
    assert has_element?(view, "#paths-modal")
    assert Providers.get_provider!(provider.id).path_overrides == %{}
  end

  test "capacidades: quitar el override devuelve la capacidad a su default", %{conn: conn} do
    provider = create_provider(%{path_overrides: %{"chat" => "/v1/chat"}})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#paths-#{provider.id}") |> render_click()
    assert has_element?(view, "#paths-form input[name='paths[chat]'][value='/v1/chat']")

    html = view |> form("#paths-form", paths: %{chat: ""}) |> render_submit()

    assert html =~ "Paths restablecidos"
    assert Providers.get_provider!(provider.id).path_overrides == %{}
  end

  test "capacidades: un builtin también puede sobrescribir sus paths", %{conn: conn} do
    {:ok, builtin} =
      %Providers.Provider{}
      |> Ecto.Changeset.change(
        key: "catalog-paths-#{unique()}",
        name: "Catalog Paths #{unique()}",
        base_url: "https://catalog-#{unique()}.example.com/v1",
        source: "builtin",
        dialect: "openai",
        capabilities: ["llm"],
        status: "active"
      )
      |> Tokengate.Repo.insert()

    {:ok, _cred} =
      Providers.create_credential(%{
        provider_id: builtin.id,
        name: "Producción",
        api_key_encrypted: "«redacted:sk-…»",
        status: "active"
      })

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    view |> element("#paths-#{builtin.id}") |> render_click()

    html =
      view
      |> form("#paths-form", paths: %{image: "/v1/images"})
      |> render_submit()

    assert html =~ "Paths actualizados (1 override)."

    reloaded = Providers.get_provider!(builtin.id)
    assert reloaded.path_overrides == %{"image" => "/v1/images"}
    # Identity stays catalog-owned.
    assert reloaded.name == builtin.name
    assert reloaded.base_url == builtin.base_url
  end

  ## Client ids and stale rows (F6/F8) -------------------------------------

  # Every id that arrives in an event payload is untrusted: a non-UUID used to
  # raise Ecto.Query.CastError and an unknown UUID Ecto.NoResultsError inside
  # get_provider!/1 — both killed the LiveView mid-render.
  test "un id malformado o inexistente no tumba la LiveView", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    for event <- ~w(edit_provider edit_paths toggle_provider) do
      html = render_click(view, event, %{"id" => "no-es-un-uuid"})
      assert html =~ "El proveedor ya no existe."

      html = render_click(view, event, %{"id" => Ecto.UUID.generate()})
      assert html =~ "El proveedor ya no existe."
    end

    # No clause matched this event either: the catch-all keeps the page alive
    # instead of raising FunctionClauseError.
    html = render_click(view, "evento_desconocido", %{"id" => provider.id})
    assert html =~ "Proveedores"

    # The page still works after all of that.
    view |> element("#edit-#{provider.id}") |> render_click()
    assert has_element?(view, "#provider-form")
  end

  test "guardar el form de un proveedor que ya no existe no revienta", %{conn: conn} do
    provider = create_provider(%{name: "stale-#{unique()}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#edit-#{provider.id}") |> render_click()
    assert has_element?(view, "#provider-form")

    # Another admin deletes it while this form is open.
    {:ok, _} = Providers.delete_provider(provider)

    html =
      view
      |> form("#provider-form", provider: %{name: "renombrado"})
      |> render_submit()

    assert html =~ "El proveedor ya no existe."
    refute has_element?(view, "#provider-form")
    refute has_element?(view, "#edit-#{provider.id}")
  end

  # A submit already in flight lands right after Cancel cleared the modal
  # assign; get_provider!(nil) used to crash the LiveView on that path.
  test "save_paths después de cancelar no llama get_provider!(nil)", %{conn: conn} do
    provider = create_provider(%{path_overrides: %{"chat" => "/v1/chat"}})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#paths-#{provider.id}") |> render_click()
    assert has_element?(view, "#paths-modal")

    # El contenedor es el .modal compartido: su ✕ (con aria-label traducido) es
    # el mismo cierre que Escape y el click-away.
    view |> element("#paths-modal button[aria-label='Cerrar']") |> render_click()
    refute has_element?(view, "#paths-modal")

    html = render_click(view, "save_paths", %{"paths" => %{"image" => "/v1/images"}})

    assert html =~ "El proveedor ya no existe."
    refute has_element?(view, "#paths-modal")
    # Nothing was written by the stale submit.
    assert Providers.get_provider!(provider.id).path_overrides == %{"chat" => "/v1/chat"}
  end

  # The old guard only counted lanes served by the provider's KEYS; a lane
  # mounted on one of its credential pools (credential_id NULL) read as unused
  # and took the whole provider with it.
  test "borrar un proveedor con lanes por pool se bloquea", %{conn: conn} do
    provider = create_provider()

    u = unique()

    {:ok, model_} =
      Providers.create_model(%{
        name: "gpt-4o-pool-#{u}",
        context_window: 128_000
      })

    {:ok, pool} = Providers.create_pool(provider, %{name: "pool-#{u}"})

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-pooled",
        status: "active"
      })

    {:ok, _member} = Providers.add_pool_member(pool, credential)

    {:ok, _lane} =
      Providers.create_model_provider(%{
        model_id: model_.id,
        pool_id: pool.id,
        provider_model: "gpt-4-turbo",
        enabled: true,
        priority: 1
      })

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "está en uso por uno o más modelos"
    assert has_element?(view, "#edit-#{provider.id}")
    assert Providers.get_provider(provider.id)
  end

  test "borrar un proveedor que otro admin ya borró no revienta", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    {:ok, _} = Providers.delete_provider(provider)

    html = view |> element("#delete-#{provider.id}") |> render_click()

    assert html =~ "El proveedor ya no existe."
    refute has_element?(view, "#edit-#{provider.id}")
  end
end
