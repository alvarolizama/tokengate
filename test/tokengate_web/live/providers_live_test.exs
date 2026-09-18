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

  # El grid de 2 columnas se pina por clases: ExUnit no puede medir el layout.
  # La paridad de alturas por fila y el 2-por-fila real se midieron en el
  # navegador (1512/1280/1100/1024 → 2 por fila; 900 → 1 por fila).
  test "la lista de proveedores es un grid de dos columnas", %{conn: conn} do
    create_provider(%{name: "grid-prov-a-#{unique()}"})
    create_provider(%{name: "grid-prov-b-#{unique()}"})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    assert has_element?(view, "#providers.grid.gap-3.lg\\:grid-cols-2")
    refute has_element?(view, "#providers.space-y-3")
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
        billing_type: "pay_per_token",
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

    # The entry point is the catalog modal; "Custom provider" lives inside it.
    view |> element("#add-provider-btn") |> render_click()
    assert has_element?(view, "#catalog-modal")
    view |> element("#new-custom-provider-btn") |> render_click()
    assert has_element?(view, "#provider-form")
    refute has_element?(view, "#catalog-modal")

    # Capabilities are code configuration, not a form field: a custom only
    # takes name + base URL.
    refute has_element?(view, "#provider_capabilities")
    refute has_element?(view, "#provider-form input[name='provider[capabilities][]']")

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

    # A custom has no catalog entry to derive capabilities from, so what gets
    # stored is the schema default (chat).
    created = Tokengate.Repo.get_by!(Providers.Provider, name: "anthropic")
    assert created.capabilities == ["llm"]

    # El custom aparece en la misma lista que los builtin (ya no hay tab).
    assert render(view) =~ "anthropic"
  end

  test "editing a provider leaves its capabilities alone (not a form field)", %{conn: conn} do
    provider = create_provider(%{capabilities: ["llm", "embedding", "stt"]})
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    view |> element("#edit-#{provider.id}") |> render_click()
    refute has_element?(view, "#provider_capabilities")
    # Neither the form nor the card shows the set anymore.
    refute render(view) =~ "stt"

    html = view |> form("#provider-form", provider: %{max_rpm: "60"}) |> render_submit()
    assert html =~ "Proveedor actualizado."

    reloaded = Providers.get_provider!(provider.id)
    assert reloaded.max_rpm == 60
    # The form never mentions them, so the stored set is untouched.
    assert reloaded.capabilities == ["llm", "embedding", "stt"]
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

  ## Credential management -------------------------------------------------

  test "admin manages credentials for a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

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
          api_key_encrypted: "sk-tes...abcd"
        }
      )
      |> render_submit()

    assert html =~ "Credencial creada."
    assert html =~ "Producción"
    assert html =~ "••••••abcd"

    [cred] = Providers.list_credentials_for_provider(provider.id)

    # Edit the credential — cambiar el alias y dejar API key vacío
    view |> element("#edit-credential-#{cred.id}") |> render_click()
    assert has_element?(view, "#credential-form")

    html =
      view
      |> form("#credential-form",
        credential: %{
          name: "Staging",
          api_key_encrypted: ""
        }
      )
      |> render_submit()

    assert html =~ "Credencial actualizada."
    assert html =~ "Staging"

    # Verificar que el API key NO se perdió
    [updated] = Providers.list_credentials_for_provider(provider.id)
    assert updated.api_key_encrypted == "sk-tes...abcd"
    assert updated.name == "Staging"

    # Toggle it off
    html = view |> element("#toggle-credential-btn-#{cred.id}") |> render_click()
    assert html =~ "desactivada"

    # Delete it
    html = view |> element("#delete-credential-#{cred.id}") |> render_click()
    assert html =~ "Credencial eliminada."
    refute has_element?(view, "#credential-#{cred.id}")
  end

  ## Builtin (catalog) providers ------------------------------------------------

  test "catálogo: el modal busca en el espejo y activa un proveedor", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/providers")

    refute has_element?(view, "#catalog-modal")
    view |> element("#add-provider-btn") |> render_click()
    assert has_element?(view, "#catalog-modal")

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

    # Activating a provider opens the credential modal pre-assigned to it.
    view |> render_change("search_catalog", %{"query" => "fireworks"})
    view |> element("#activate-catalog-fireworks-ai") |> render_click()

    refute has_element?(view, "#catalog-modal")
    assert has_element?(view, "#credential-form")

    provider = Tokengate.Repo.get_by!(Providers.Provider, key: "fireworks-ai")

    assert has_element?(
             view,
             "#credential-form input[name='credential[provider_id]'][value='#{provider.id}']"
           )
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

  test "credential button is labeled 'API key' to distinguish from activating providers", %{
    conn: conn
  } do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_providers(conn)

    assert has_element?(view, "#new-credential-#{provider.id}")
    assert render(view) =~ "API key"
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
      |> form("#paths-form", paths: %{chat: "/v1/chat", video: "/v1/videos"})
      |> render_submit()

    assert html =~ "Paths actualizados (2 overrides)."
    refute has_element?(view, "#paths-modal")

    reloaded = Providers.get_provider!(provider.id)
    assert reloaded.path_overrides == %{"chat" => "/v1/chat", "video" => "/v1/videos"}

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
        billing_type: "pay_per_token",
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
end
