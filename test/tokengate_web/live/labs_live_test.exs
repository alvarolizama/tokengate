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
      assert render(view) =~ "De catálogo"
    end

    test "la marca usa el logo cuando lo hay", %{conn: conn} do
      lab = create_lab(%{"logo_url" => "https://cdn.example.com/l.png"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      assert has_element?(view, "#lab-mark-#{lab.key} img[src='https://cdn.example.com/l.png']")
    end

    test "el filtro por origen y la búsqueda", %{conn: conn} do
      lab = create_lab(%{"name" => "Zzz Unique Lab"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/labs")

      # Sólo custom: openai desaparece, el custom queda.
      view |> element("#lab-tab-custom") |> render_click()
      assert has_element?(view, "#lab-name-#{lab.key}")
      refute has_element?(view, "#lab-name-openai")

      # Búsqueda por nombre.
      view |> element("#search-form") |> render_change(%{"q" => "Zzz Unique"})
      assert has_element?(view, "#lab-name-#{lab.key}")

      # Búsqueda sin resultados → estado vacío.
      view |> element("#search-form") |> render_change(%{"q" => "no-existe-nada"})
      assert has_element?(view, "#labs-empty")
      refute has_element?(view, "#lab-name-#{lab.key}")
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

      assert html =~ "has already been taken" or html =~ "ya existe"
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

  describe "marca (Lab.mark/1)" do
    test "la precedencia logo > icono > default", %{conn: _conn} do
      assert Lab.mark(%Lab{logo_url: "https://x/l.svg", icon: "hero-fire"}) ==
               {:logo, "https://x/l.svg"}

      assert Lab.mark(%Lab{icon: "hero-fire"}) == {:icon, "hero-fire"}
      assert Lab.mark(%Lab{}) == {:icon, LabCatalog.default_icon()}
    end
  end
end
