defmodule TokengateWeb.LabsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.{Lab, LabCatalog}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "lab-#{u}@example.com",
        name: "Lab #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma los mensajes en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, %{user: user, password: password}) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp admin_conn(conn), do: login(conn, register("admin"))
  defp user_conn(conn), do: login(conn, register("user"))

  defp create_lab(attrs \\ %{}) do
    u = unique()

    {:ok, lab} =
      Providers.create_custom_lab(Map.merge(%{"name" => "Lab #{u}", "key" => "lab-#{u}"}, attrs))

    lab
  end

  describe "acceso" do
    test "un no-admin no entra", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(user_conn(conn), ~p"/catalog/labs")
    end
  end

  describe "listado" do
    test "muestra los labs builtin de models.dev", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      # El snapshot trae 37 labs; openai siempre está.
      assert has_element?(view, "#lab-name-openai", "OpenAI")
      assert has_element?(view, "#lab-badge-openai", "builtin")
      refute has_element?(view, "#edit-lab-openai")
      refute has_element?(view, "#delete-lab-openai")
    end

    test "un lab custom aparece con sus acciones", %{conn: conn} do
      lab = create_lab(%{"name" => "Mi Lab", "icon" => "hero-sparkles"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "#lab-name-#{lab.key}", "Mi Lab")
      assert has_element?(view, "#lab-badge-#{lab.key}", "custom")
      assert has_element?(view, "#edit-lab-#{lab.key}")
      assert has_element?(view, "#delete-lab-#{lab.key}")

      # Sin logo, la marca es el icono elegido.
      assert has_element?(view, "#lab-mark-#{lab.key} .hero-sparkles")
    end

    test "las acciones del custom van al mismo nivel que el nombre (arriba a la derecha)", %{
      conn: conn
    } do
      lab = create_lab(%{"name" => "Mi Lab"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      # Editar/Eliminar viven en la MISMA fila que el nombre: en el HTML de la
      # tarjeta aparecen antes del bloque de metadatos (`mt-3`) y después del
      # nombre, en lugar de en un bloque de acciones al final.
      html = render(view)
      name_pos = elem(:binary.match(html, "lab-name-#{lab.key}"), 0)
      actions_pos = elem(:binary.match(html, ~s(id="edit-lab-#{lab.key}")), 0)
      delete_pos = elem(:binary.match(html, ~s(id="delete-lab-#{lab.key}")), 0)

      assert name_pos < actions_pos, "Editar debe ir después del nombre"
      assert name_pos < delete_pos, "Eliminar debe ir después del nombre"

      # Y no quedan duplicados: una sola instancia de cada botón en la tarjeta.
      assert length(Regex.scan(~r/id="edit-lab-#{lab.key}"/, html)) == 1
      assert length(Regex.scan(~r/id="delete-lab-#{lab.key}"/, html)) == 1
    end

    test "un lab de catálogo no tiene acciones y conserva su etiqueta", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "#lab-name-openai", "OpenAI")
      refute has_element?(view, "#edit-lab-openai")
      refute has_element?(view, "#delete-lab-openai")
      assert render(view) =~ "Desde catálogo"
    end

    test "la marca usa el logo cuando lo hay", %{conn: conn} do
      lab = create_lab(%{"logo_url" => "https://cdn.example.com/l.png"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "#lab-mark-#{lab.key} img[src='https://cdn.example.com/l.png']")
    end

    test "listado en tabla con buscador y filtros muestra builtin y custom juntos", %{conn: conn} do
      lab = create_lab(%{"name" => "Zzz Unique Lab"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "tbody#labs[phx-update='stream']")
      assert has_element?(view, "#search-form #lab-search")
      assert has_element?(view, "#lab-filter-pills")
      refute has_element?(view, "#lab-source-tabs")

      # Las dos fuentes conviven en el listado bajo "All".
      assert has_element?(view, "#lab-name-openai")
      assert has_element?(view, "#lab-name-#{lab.key}")
    end

    test "búsqueda, filtros All/Custom/Builtin, ordenamiento y enlace a modelos", %{conn: conn} do
      lab = create_lab(%{"name" => "Zzz Searchable Lab", "key" => "zzz-search-#{unique()}"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      # Clickable model_count link to /catalog/models?q=<lab.key>
      assert has_element?(
               view,
               "a#lab-models-#{lab.key}[href='/catalog/models?q=#{lab.key}']"
             )

      # Search filters by name or key
      view |> element("#search-form") |> render_change(%{"q" => lab.key})
      assert has_element?(view, "#lab-#{lab.key}")
      refute has_element?(view, "#lab-openai")

      view |> element("#search-form") |> render_change(%{"q" => "zzz-no-match-#{unique()}"})
      assert has_element?(view, "#labs-empty")

      view |> element("#search-form") |> render_change(%{"q" => ""})
      assert has_element?(view, "#lab-openai")

      # Filter pills: Custom / Builtin / All
      view |> element("#filter-lab-source-custom") |> render_click()
      assert has_element?(view, "#filter-lab-source-custom.btn-primary")
      assert has_element?(view, "#lab-#{lab.key}")
      refute has_element?(view, "#lab-openai")

      view |> element("#filter-lab-source-builtin") |> render_click()
      assert has_element?(view, "#lab-openai")
      refute has_element?(view, "#lab-#{lab.key}")

      view |> element("#filter-lab-source-all") |> render_click()
      assert has_element?(view, "#lab-#{lab.key}")
      assert has_element?(view, "#lab-openai")

      # Sortable columns
      view |> element("button[phx-click='sort_labs'][phx-value-field='name']") |> render_click()
      view |> element("button[phx-click='sort_labs'][phx-value-field='source']") |> render_click()

      view
      |> element("button[phx-click='sort_labs'][phx-value-field='model_count']")
      |> render_click()

      view
      |> element("button[phx-click='sort_labs'][phx-value-field='last_updated']")
      |> render_click()

      assert Process.alive?(view.pid)
    end

    test "lab_mark siempre renderiza img[data-logo] con icono sibling oculto para fallback", %{
      conn: conn
    } do
      with_logo =
        create_lab(%{
          "logo_url" => "https://cdn.example.com/404.png",
          "icon" => "hero-sparkles"
        })

      without_logo = create_lab(%{"icon" => "hero-rocket-launch"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(
               view,
               "#lab-mark-#{with_logo.key} img[data-logo][src='https://cdn.example.com/404.png']"
             )

      assert has_element?(view, "#lab-mark-#{with_logo.key} .hero-sparkles.hidden")

      refute has_element?(view, "#lab-mark-#{without_logo.key} img[data-logo]")
      assert has_element?(view, "#lab-mark-#{without_logo.key} .hero-rocket-launch")
      refute has_element?(view, "#lab-mark-#{without_logo.key} .hero-rocket-launch.hidden")
    end
  end

  describe "crear" do
    test "crea un lab custom con icono y lo muestra en el listado", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "#new-lab-btn")

      view |> element("#new-lab-btn") |> render_click()
      assert has_element?(view, "#lab-form")

      # El picker setea el icono del form.
      view |> element("#icon-choice-hero-rocket-launch") |> render_click()

      view
      |> element("#lab-form")
      |> render_submit(%{
        "lab" => %{
          "name" => "Custom Rocket",
          "key" => "custom-rocket",
          "icon" => "hero-rocket-launch",
          "logo_url" => ""
        }
      })

      assert has_element?(view, "#lab-name-custom-rocket", "Custom Rocket")
      assert has_element?(view, "#lab-mark-custom-rocket .hero-rocket-launch")

      lab = Providers.get_lab!("custom-rocket")
      assert lab.source == "custom"
      assert lab.icon == "hero-rocket-launch"
    end

    test "un key duplicado re-renderiza el form con el error", %{conn: conn} do
      create_lab(%{"key" => "duplicado"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")
      view |> element("#new-lab-btn") |> render_click()

      html =
        view
        |> element("#lab-form")
        |> render_submit(%{"lab" => %{"name" => "Otro", "key" => "duplicado"}})

      assert html =~ "has already been taken" or html =~ "ya está en uso"
      # El form sigue abierto.
      assert has_element?(view, "#lab-form")
    end

    test "un key inválido se rechaza", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")
      view |> element("#new-lab-btn") |> render_click()

      html =
        view
        |> element("#lab-form")
        |> render_submit(%{"lab" => %{"name" => "Malo", "key" => "Con Espacios"}})

      assert html =~ "minúsculas"
      assert has_element?(view, "#lab-form")
    end
  end

  describe "editar" do
    test "cambia nombre, logo e icono", %{conn: conn} do
      lab = create_lab(%{"name" => "Antes", "icon" => "hero-beaker"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      view |> element("#edit-lab-#{lab.key}") |> render_click()
      assert has_element?(view, "#lab-form")

      # El key no se puede tocar al editar.
      assert has_element?(view, "#lab-form input[name='lab[key]'][disabled]")

      view
      |> element("#lab-form")
      |> render_submit(%{
        "lab" => %{
          "name" => "Después",
          "key" => lab.key,
          "icon" => "hero-fire",
          "logo_url" => "https://cdn.example.com/n.svg"
        }
      })

      assert has_element?(view, "#lab-name-#{lab.key}", "Después")
      assert has_element?(view, "#lab-mark-#{lab.key} img")

      reloaded = Providers.get_lab!(lab.key)
      assert reloaded.name == "Después"
      assert reloaded.icon == "hero-fire"
    end
  end

  describe "eliminar" do
    test "borra un lab custom", %{conn: conn} do
      lab = create_lab()

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      view |> element("#delete-lab-#{lab.key}") |> render_click()
      assert has_element?(view, "#delete-lab-modal")

      view |> element("#confirm-delete-lab") |> render_click()

      refute Providers.get_lab(lab.key)
      refute has_element?(view, "#lab-name-#{lab.key}")
    end
  end

  describe "formulario (F19/F6)" do
    test "elegir un icono de la paleta NO borra el nombre ni el logo tecleados", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")
      view |> element("#new-lab-btn") |> render_click()

      # Lo tecleado viaja al servidor en el phx-change…
      view
      |> form("#lab-form", %{
        "lab" => %{
          "name" => "Lab Tecleado",
          "key" => "lab-tecleado",
          "logo_url" => "https://cdn.example.com/typed.svg",
          "icon" => "hero-beaker"
        }
      })
      |> render_change()

      # …y el click de la paleta es el SIGUIENTE render del servidor: sin el
      # phx-change del form, el changeset volvía a los valores persistidos y el
      # nombre/logo tecleados desaparecían de los inputs.
      view |> element("#icon-choice-hero-fire") |> render_click()

      assert has_element?(view, "#lab-form input[name='lab[name]'][value='Lab Tecleado']")

      assert has_element?(
               view,
               "#lab-form input[name='lab[logo_url]'][value='https://cdn.example.com/typed.svg']"
             )

      assert has_element?(view, "#lab-form input[name='lab[icon]'][value='hero-fire']")
    end

    test "un key de lab inexistente no tumba la LiveView", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      render_click(view, "edit_lab", %{"key" => "no-existe"})
      refute has_element?(view, "#lab-form")
      assert has_element?(view, "#flash-error")

      render_click(view, "confirm_delete", %{"key" => "no-existe"})
      refute has_element?(view, "#delete-lab-modal")
      assert has_element?(view, "#flash-error")

      # A non-binary payload is not a key either.
      render_click(view, "edit_lab", %{"key" => 123})
      refute has_element?(view, "#lab-form")
      assert has_element?(view, "#flash-error")
    end

    test "un lab de catálogo no se puede editar por un evento forjado", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      # La UI no ofrece el lápiz en un builtin; el evento directo tampoco abre
      # el form (el lab lo escribe el refresh de models.dev).
      render_click(view, "edit_lab", %{"key" => "openai"})

      refute has_element?(view, "#lab-form")
      assert has_element?(view, "#flash-error")
    end

    test "borrar un lab inexistente responde con error, no con un crash", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      render_click(view, "delete_lab", %{"id" => "no-existe"})

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#lab-name-openai")
    end
  end

  describe "marca (Lab.mark/1)" do
    test "la precedencia logo > icono > default", %{conn: _conn} do
      assert Lab.mark(%Lab{logo_url: "https://x/l.svg", icon: "hero-fire"}) ==
               {:logo, "https://x/l.svg"}

      assert Lab.mark(%Lab{icon: "hero-fire"}) == {:icon, "hero-fire"}
      assert Lab.mark(%Lab{}) == {:icon, LabCatalog.default_icon()}
    end

    test "pick_icon with nil form is a safe no-op", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      render_click(view, "pick_icon", %{"icon" => "hero-fire"})
      assert has_element?(view, "#lab-name-openai")
    end
  end
end
