defmodule TokengateWeb.ProviderKeysLiveTest do
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

  defp create_provider(attrs \\ %{}) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(
          %{name: "Prov #{u}", base_url: "https://api-#{u}.example.com/v1"},
          attrs
        )
      )

    provider
  end

  defp create_credential(provider, attrs) do
    {:ok, credential} =
      Providers.create_credential(
        Map.merge(
          %{
            provider_id: provider.id,
            name: "Prod #{unique()}",
            api_key_encrypted: "sk-test-abcd",
            status: "active"
          },
          attrs
        )
      )

    credential
  end

  defp live_keys(conn, provider) do
    live(conn, ~p"/catalog/providers/#{provider.id}/keys")
  end

  ## Permissions -----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    provider = create_provider()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/catalog/providers/#{provider.id}/keys")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    provider = create_provider()
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/catalog/providers/#{provider.id}/keys")
  end

  # Un id que no existe (o que ni siquiera es un UUID) no revienta el mount:
  # cae en el índice de proveedores.
  test "an unknown provider id falls back to the providers list", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/catalog/providers"}}} =
             live(conn, ~p"/catalog/providers/2f1c2b1e-0000-4000-8000-000000000000/keys")

    assert {:error, {:redirect, %{to: "/catalog/providers"}}} =
             live(conn, "/catalog/providers/no-es-un-uuid/keys")
  end

  ## The page --------------------------------------------------------------

  test "the page lists the keys of THIS provider only", %{conn: conn} do
    provider = create_provider()
    other = create_provider()
    credential = create_credential(provider, %{name: "Producción"})
    foreign = create_credential(other, %{name: "Ajena"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    assert has_element?(view, "tbody#keys-table")
    assert has_element?(view, "#credential-#{credential.id}", "Producción")
    # La key se muestra enmascarada, nunca completa.
    assert has_element?(view, "#credential-#{credential.id}", "••••••abcd")
    refute render(view) =~ "sk-test-abcd"

    refute has_element?(view, "#credential-#{foreign.id}")
  end

  test "a provider with no keys shows the empty state", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    assert has_element?(view, "#keys-empty")
    refute has_element?(view, "tbody#keys-table")
  end

  # Los límites son del proveedor: aquí se muestran, no se editan. El botón de
  # alta no se confunde con el de activar un proveedor del catálogo.
  test "limits are shown as inherited and the alta button says 'API key'", %{conn: conn} do
    provider =
      create_provider(%{
        max_rpm: 120,
        max_concurrent: 8,
        max_concurrent_per_user: 2,
        receive_timeout_ms: 90_000
      })

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, html} = live_keys(conn, provider)

    assert has_element?(view, "#keys-provider-limits", "RPM 120")
    assert has_element?(view, "#keys-provider-limits", "Conc. 8")
    assert has_element?(view, "#keys-provider-limits", "Conc./usuario 2")
    assert has_element?(view, "#keys-provider-limits", "90000 ms")

    # No hay form de límites en esta página: se editan en el índice.
    refute has_element?(view, "#provider-form")

    assert has_element?(view, "#new-credential-#{provider.id}")
    assert html =~ "API key"
  end

  test "?new=1 opens the alta modal pre-assigned to the provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)

    {:ok, view, _html} =
      live(conn, ~p"/catalog/providers/#{provider.id}/keys?new=1")

    assert has_element?(view, "#credential-form")

    # El contenedor es el .modal único: su id va en el div raíz.
    assert has_element?(view, "#credential-form-modal")

    assert has_element?(
             view,
             "#credential-form input[name='credential[provider_id]'][value='#{provider.id}']"
           )
  end

  # The alta modal opens from `handle_params`, so a patch that only changes the
  # query string opens it too — and the rows load through that same path.
  test "?new=1 opens the modal through handle_params on a patch", %{conn: conn} do
    provider = create_provider()
    credential = create_credential(provider, %{name: "Producción"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    refute has_element?(view, "#credential-form")

    view |> render_patch(~p"/catalog/providers/#{provider.id}/keys?new=1")

    assert has_element?(view, "#credential-form")

    # El contenedor es el .modal único: su id va en el div raíz.
    assert has_element?(view, "#credential-form-modal")

    assert has_element?(
             view,
             "#credential-form input[name='credential[provider_id]'][value='#{provider.id}']"
           )

    assert has_element?(view, "#credential-#{credential.id}", "Producción")
  end

  test "admin manages the keys of a provider", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

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
      |> form("#credential-form", credential: %{name: "Staging", api_key_encrypted: ""})
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
    assert has_element?(view, "#keys-empty")
  end

  # Una key en error (401/402/403 del upstream) no se togglea: se reactiva.
  test "a key in error is reactivated, not toggled", %{conn: conn} do
    provider = create_provider()
    credential = create_credential(provider, %{status: "error"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    refute has_element?(view, "#toggle-credential-btn-#{credential.id}")
    assert has_element?(view, "#reactivate-credential-#{credential.id}")

    html = view |> element("#reactivate-credential-#{credential.id}") |> render_click()

    assert html =~ "Credencial reactivada."
    assert Providers.get_credential!(credential.id).status == "active"
  end

  # Una key que vive en un pool no se borra: la membresía es parte de la fuente
  # de credenciales de un lane (FK RESTRICT). El contexto la rechaza y la UI lo
  # dice, en vez de reventar con un 500.
  test "una key que vive en un pool no se borra y se avisa", %{conn: conn} do
    provider = create_provider()
    credential = create_credential(provider, %{name: "Pooled"})

    {:ok, pool} = Providers.create_pool(provider, %{name: "Pool de keys"})
    {:ok, _member} = Providers.add_pool_member(pool, credential)

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    html = view |> element("#delete-credential-#{credential.id}") |> render_click()

    assert html =~ "Esta API key pertenece a un pool. Quítala del pool primero."
    assert has_element?(view, "#credential-#{credential.id}")
    assert Providers.get_credential(credential.id) != nil
  end

  ## The secret never comes back to the DOM --------------------------------

  # P3: the edit modal edits the alias, not the secret. Neither a prefilled
  # struct nor a `value=` on the password input may return the stored key to the
  # markup (two guards: the changeset clears the field and
  # `CoreComponents.input/1` renders no `value` for type=password).
  test "the edit modal never renders the stored secret", %{conn: conn} do
    provider = create_provider()
    credential = create_credential(provider, %{api_key_encrypted: "sk-liv...eak"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    html = view |> element("#edit-credential-#{credential.id}") |> render_click()

    assert has_element?(view, "#credential-form")
    refute html =~ "sk-liv...eak"

    password_input =
      view
      |> element("#credential-form input[name='credential[api_key_encrypted]']")
      |> render()

    refute password_input =~ "value="

    # The alias IS prefilled: that is what gets edited.
    assert has_element?(
             view,
             "#credential-form input[name='credential[name]'][value='#{credential.name}']"
           )
  end

  # The alta takes the provider of the PAGE: the hidden field belongs to the
  # client and cannot divert the secret to another provider.
  test "the alta assigns the key to the provider of the page, not to the form field", %{
    conn: conn
  } do
    provider = create_provider()
    other = create_provider()

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    view |> element("#new-credential-#{provider.id}") |> render_click()

    # A forged submit: the payload names the OTHER provider.
    html =
      render_submit(view, "save_credential", %{
        "credential" => %{
          "provider_id" => other.id,
          "name" => "Forjada",
          "api_key_encrypted" => "sk-test-wxyz"
        }
      })

    assert html =~ "Credencial creada."
    refute html =~ "sk-test-wxyz"

    assert [credential] = Providers.list_credentials_for_provider(provider.id)
    assert credential.name == "Forjada"
    assert Providers.list_credentials_for_provider(other.id) == []
  end

  # A forged submit of the edit modal cannot move lifecycle state nor re-parent
  # the credential: only the alias (and the secret, when a new one is typed) are
  # operator-owned.
  test "a forged status or provider_id in the edit submit is ignored", %{conn: conn} do
    provider = create_provider()
    other = create_provider()
    credential = create_credential(provider, %{name: "Producción", status: "disabled"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    view |> element("#edit-credential-#{credential.id}") |> render_click()

    # Forged payload: it tries to activate the key and move it to the other provider.
    html =
      render_submit(view, "save_credential", %{
        "credential" => %{
          "name" => "Staging",
          "api_key_encrypted" => "",
          "provider_id" => other.id,
          "status" => "active",
          "error_reason" => "unauthorized"
        }
      })

    assert html =~ "Credencial actualizada."

    updated = Providers.get_credential!(credential.id)
    assert updated.name == "Staging"
    assert updated.status == "disabled"
    assert updated.provider_id == provider.id
    assert is_nil(updated.error_reason)
    assert updated.api_key_encrypted == credential.api_key_encrypted
  end

  # Every credential resolves against the provider of the page: a foreign id is
  # not toggled, edited or deleted, and the LiveView stays alive.
  test "an event aimed at another provider's key is refused and the page survives", %{
    conn: conn
  } do
    provider = create_provider()
    other = create_provider()
    foreign = create_credential(other, %{name: "Ajena"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    for event <-
          ~w(edit_credential toggle_credential reactivate_credential reset_breaker delete_credential) do
      html = render_click(view, event, %{"id" => foreign.id})
      assert html =~ "Esta API key no pertenece a este proveedor."
    end

    assert has_element?(view, "#keys-empty")
    refute has_element?(view, "#credential-form")

    unchanged = Providers.get_credential!(foreign.id)
    assert unchanged.status == "active"
    assert unchanged.name == "Ajena"
  end

  # A non-UUID id (CastError) and a missing one (NoResultsError) used to be two
  # different crashes; they are now the same answer and the page survives.
  test "ids that are not UUIDs or do not exist do not kill the page", %{conn: conn} do
    provider = create_provider()
    credential = create_credential(provider, %{name: "Producción"})

    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)
    {:ok, view, _html} = live_keys(conn, provider)

    for bad_id <- ["no-es-un-uuid", Ecto.UUID.generate()] do
      for event <-
            ~w(edit_credential toggle_credential reactivate_credential reset_breaker delete_credential) do
        html = render_click(view, event, %{"id" => bad_id})
        assert html =~ "Esta API key no pertenece a este proveedor."
      end
    end

    assert has_element?(view, "#credential-#{credential.id}", "Producción")
    assert Providers.get_credential!(credential.id).name == "Producción"
  end
end
