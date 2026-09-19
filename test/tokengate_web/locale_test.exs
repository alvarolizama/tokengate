defmodule TokengateWeb.LocaleTest do
  @moduledoc """
  Idioma de la UI: inglés por defecto y selector EN/ES al lado de la zona horaria.

  Fija las piezas del montaje:

    * la UI sale en **inglés** cuando el usuario no ha elegido nada
      (`default_locale: "en"`, columna `users.locale` en `"en"`);
    * el selector del sidebar (`#locale-select`, evento `set-locale`) guarda la
      elección en `users.locale` y remonta el LiveView en su misma ruta
      (`{:live_redirect, kind: :push}`) para que **todo** el texto se vuelva a
      pintar en el idioma nuevo — el diff de LiveView no reenvía el texto ya
      renderizado de los componentes, así que sin el remonte las etiquetas se
      quedan en el idioma anterior;
    * el plug `TokengateWeb.Plugs.Locale` aplica el idioma del usuario en las
      requests que no son LiveView (el LiveView lo reaplica en `on_mount`,
      porque Gettext guarda el locale en el process dictionary).

  Y lo que **no** debe pasar: un locale inventado (p. ej. `"fr"`) cae al de
  reserva y no se guarda.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias TokengateWeb.Gettext

  defp unique, do: System.unique_integer([:positive])

  defp register(role \\ "admin") do
    u = unique()
    password = "password-secret-#{u}1"

    {:ok, user} =
      Accounts.register_user(%{
        email: "locale-#{u}@example.com",
        name: "Locale #{u}",
        password: password,
        global_role: role
      })

    %{user: user, password: password}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  test "por defecto la UI sale en inglés", %{conn: conn} do
    %{user: admin, password: password} = register()

    assert admin.locale == "en"

    conn = login(conn, admin, password)
    {:ok, view, page} = live(conn, ~p"/dashboard")

    # Etiquetas del sidebar en inglés; el selector de idioma se pinta con
    # bandera + código ISO (mismo texto en cualquier idioma).
    assert page =~ ~s(lang="en")
    assert has_element?(view, "#sidebar-section-budget", "Budget")
    refute has_element?(view, "#sidebar-section-budget", "Presupuesto")
    assert has_element?(view, "#sidebar-section-catalogo", "Catalog")
    assert has_element?(view, "#locale-select option[value=en][selected]", "🇬🇧 EN")
    assert has_element?(view, "#timezone-selector", "Timezone")
  end

  test "el selector guarda el idioma y la página se repinta en español", %{conn: conn} do
    %{user: admin, password: password} = register()
    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/dashboard")

    # Cambia el idioma: persiste y remonta el LiveView en la misma ruta.
    assert {:error, {:live_redirect, %{kind: :push, to: "/dashboard"}}} =
             render_change(view, "set-locale", %{"locale" => "es"})

    assert Accounts.get_user!(admin.id).locale == "es"

    # El LiveView remontado (el que ya ve el usuario) sale entero en español.
    {:ok, fresh, page} = live(recycle(conn), ~p"/dashboard")
    assert page =~ ~s(lang="es")
    assert has_element?(fresh, "#sidebar-section-budget", "Presupuesto")
    refute has_element?(fresh, "#sidebar-section-budget", "Budget")
    assert has_element?(fresh, "#sidebar-section-catalogo", "Catálogo")
    refute has_element?(fresh, "#sidebar-section-catalogo", "Catalog")
    assert has_element?(fresh, "#locale-select option[value=es][selected]", "🇪🇸 ES")
    assert has_element?(fresh, "#timezone-selector", "Zona horaria")
  end

  test "vuelve a inglés y un locale inventado no se guarda", %{conn: conn} do
    %{user: admin, password: password} = register()
    {:ok, admin} = Accounts.update_user_locale(admin, "es")
    conn = login(conn, admin, password)

    {:ok, view, page} = live(conn, ~p"/dashboard")
    assert page =~ ~s(lang="es")

    # es → en
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             render_change(view, "set-locale", %{"locale" => "en"})

    assert Accounts.get_user!(admin.id).locale == "en"

    {:ok, fresh, page_en} = live(recycle(conn), ~p"/dashboard")
    assert page_en =~ ~s(lang="en")
    assert has_element?(fresh, "#sidebar-section-budget", "Budget")

    # Un idioma que la UI no ofrece cae a la reserva (inglés) y NO se guarda.
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             render_change(fresh, "set-locale", %{"locale" => "fr"})

    assert Accounts.get_user!(admin.id).locale == "en"

    {:ok, _, page_fr} = live(recycle(conn), ~p"/dashboard")
    assert page_fr =~ ~s(lang="en")
  end

  test "el contenido de una sección también cambia de idioma", %{conn: conn} do
    %{user: admin, password: password} = register()
    conn = login(conn, admin, password)

    # Catálogo → Proveedores: por defecto sale en inglés, no en español.
    {:ok, view, page} = live(conn, ~p"/catalog/providers")

    assert page =~ "Add provider"
    assert page =~ "LLM providers and credentials"
    refute page =~ "Agregar proveedor"
    assert has_element?(view, "#sidebar-section-catalogo", "Catalog")

    # El panel de credenciales (`keys_panel`) y el estado vacío comparten
    # componente con las páginas de usuarios y servicios.
    assert page =~ "No providers yet."

    # El selector de zona horaria también: regiones y ciudades en inglés.
    assert has_element?(view, "#tz-select optgroup[label='America']")
    assert has_element?(view, "#tz-select", "Mexico City (CDT)")
    refute has_element?(view, "#tz-select", "América")

    # Y en español, todo lo anterior se traduce.
    {:ok, admin} = Accounts.update_user_locale(admin, "es")
    {:ok, view_es, page_es} = live(recycle(conn), ~p"/catalog/providers")

    assert page_es =~ "Agregar proveedor"
    assert page_es =~ "Providers de LLM y credenciales"
    assert has_element?(view_es, "#sidebar-section-catalogo", "Catálogo")
    assert has_element?(view_es, "#tz-select optgroup[label='América']")
    assert has_element?(view_es, "#tz-select", "Ciudad de México (CDT)")
    refute has_element?(view_es, "#tz-select", "Mexico City (CDT)")
    assert Accounts.get_user!(admin.id).locale == "es"
  end

  describe "Plug Locale (requests que no son LiveView)" do
    test "toma el locale del usuario cargado", %{conn: conn} do
      conn = init_test_session(conn, %{}) |> assign(:current_user, %{locale: "es"})
      TokengateWeb.Plugs.Locale.call(conn, [])

      assert Gettext.current_locale() == "es"
    end

    test "la sesión gana sobre el usuario y lo inválido cae a la reserva", %{conn: conn} do
      conn_es = init_test_session(assign(conn, :current_user, %{locale: "en"}), %{locale: "es"})
      TokengateWeb.Plugs.Locale.call(conn_es, [])
      assert Gettext.current_locale() == "es"

      conn_fr = init_test_session(assign(conn, :current_user, %{locale: "es"}), %{locale: "fr"})
      TokengateWeb.Plugs.Locale.call(conn_fr, [])
      assert Gettext.current_locale() == "en"

      conn_nil = init_test_session(assign(conn, :current_user, nil), %{})
      TokengateWeb.Plugs.Locale.call(conn_nil, [])
      assert Gettext.current_locale() == "en"
    end

    test "un controlador plano renderiza con el locale de la sesión", %{conn: conn} do
      # La instancia necesita un usuario: con cero, /login redirige al
      # onboarding del primer arranque en vez de renderizar el formulario.
      register()

      conn = init_test_session(conn, %{locale: "es"})
      assert get(conn, ~p"/login") |> html_response(200) =~ ~s(lang="es")

      conn = init_test_session(conn, %{locale: "en"})
      assert get(conn, ~p"/login") |> html_response(200) =~ ~s(lang="en")
    end

    test "el error de formulario sale traducido (dominio errors)", %{conn: conn} do
      # `translate_error/1` es el camino real de la UI: los mensajes de Ecto
      # llegan como `{"can't be blank", []}` y se traducen con el dominio
      # `errors` (priv/gettext/es/LC_MESSAGES/errors.po).
      Gettext.put_locale("es")

      assert TokengateWeb.CoreComponents.translate_error({"can't be blank", []}) ==
               "no puede estar vacío"

      assert TokengateWeb.CoreComponents.translate_error(
               {"must be greater than %{number}", [number: 5]}
             ) == "debe ser mayor que 5"

      # Y en inglés (la reserva) sale el msgid tal cual.
      Gettext.put_locale("en")

      assert TokengateWeb.CoreComponents.translate_error({"can't be blank", []}) ==
               "can't be blank"

      # La página plana respeta el idioma de la sesión. La instancia necesita un
      # usuario: con cero, /login redirige al onboarding y no renderiza nada.
      register()

      conn = init_test_session(conn, %{locale: "es"})
      assert get(conn, ~p"/login") |> html_response(200) =~ ~s(lang="es")
    end
  end
end
