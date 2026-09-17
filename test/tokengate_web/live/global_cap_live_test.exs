defmodule TokengateWeb.GlobalCapLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Budgets, GlobalSettings, Logs, Providers}

  # `:tokengate_budgets` es una tabla ETS nombrada (singleton): sin limpiar el
  # contador global entre tests, el gasto acumulado de un caso hace fallar al
  # siguiente. Igual que en `budgets_test.exs`.
  setup do
    :ets.delete(:tokengate_budgets, {:global, :daily})
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "global-cap-#{u}@example.com",
        name: "Global Cap #{u}",
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

  defp insert_log(cost) do
    {:ok, group} = Accounts.create_group(%{name: "Cap Group #{unique()}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "cap-owner-#{unique()}@example.com",
        name: "Owner",
        password: "password-secret-1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{unique()}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        provider_cost_usd: cost,
        prompt_tokens: 10,
        completion_tokens: 5
      })
  end

  describe "access" do
    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")

      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/budget/global")
    end
  end

  describe "el tope" do
    test "la sección vive en Presupuesto y guarda el monto", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      assert has_element?(view, "#global-cap-card")
      assert has_element?(view, "#global-cap-form")
      assert render(view) =~ "Tope diario global"

      view
      |> form("#global-cap-form", global_settings: %{daily_max_spend_usd: "50.00"})
      |> render_submit()

      assert render(view) =~ "Tope diario global actualizado"
      assert GlobalSettings.get_daily_cap() |> Decimal.to_string() =~ "50"
    end

    test "el sidebar enciende la entrada de la sección Presupuesto", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      assert has_element?(
               view,
               "#sidebar-section-budget #sidebar-link-budget-global[aria-current=page]"
             )

      refute has_element?(view, "#sidebar-link-budget-topups[aria-current]")
    end

    test "muestra el gasto real de request_logs, no el contador ETS de enforcement", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      # Gasto durable del día UTC: es el número que debe verse.
      insert_log(Decimal.new("1.25"))

      # Hold en vuelo en el contador ETS: NO debe ser el número principal.
      # Arranca en el gasto durable (semilla desde DB) y suma el hold.
      {:ok, hold} =
        Budgets.Manager.reserve(
          nil,
          nil,
          Decimal.new("10.00"),
          Decimal.new("0.25"),
          false
        )

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      # 1.25 real + 0.25 hold = 1.50 en el contador ETS.
      assert render(view) =~ "$1.25"
      refute render(view) =~ "$1.50 /"

      # Con drift, el contador de enforcement se muestra como referencia.
      assert has_element?(view, "#global-enforcement-drift")
      assert render(view) =~ "$1.50"

      :ok = Budgets.Manager.release(nil, hold)
    end

    test "sin drift no muestra la línea del contador de enforcement", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      insert_log(Decimal.new("1.250000"))

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      # El reconciliador (SyncWorker) alinea el contador ETS con la DB: ambos
      # coinciden y no hay drift que mostrar.
      :ok = Budgets.Manager.set_global_from_db(1_250_000)

      view |> element("#global-cap-card") |> render()

      refute has_element?(view, "#global-enforcement-drift")
    end
  end

  describe "exclusiones al tope" do
    test "la lista vacía anuncia que nadie está exento", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      assert has_element?(view, "#global-exemptions-empty")
      refute has_element?(view, "#global-exemptions")
    end

    test "agrega una exención a la tabla y la quita", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, target} =
        Accounts.register_user(%{
          email: "target-#{unique()}@example.com",
          name: "Target",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      view
      |> form("#global-exemption-form",
        global_subject: %{subject_type: "user", subject_id: target.id}
      )
      |> render_submit()

      assert render(view) =~ "Exención agregada."
      refute has_element?(view, "#global-exemptions-empty")

      exemption = hd(Budgets.Exemptions.list_for_scope("global_daily"))

      # La tabla nombra el tipo del sujeto en su propia columna.
      assert has_element?(view, "#global-exemption-#{exemption.id}", target.email)
      assert has_element?(view, "#global-exemption-#{exemption.id}", "Usuario")

      view
      |> element("#remove-global-exemption-#{exemption.id}")
      |> render_click()

      assert render(view) =~ "Exención eliminada."
      refute has_element?(view, "#global-exemption-#{exemption.id}")
      assert Budgets.Exemptions.list_for_scope("global_daily") == []
    end

    test "exige sujeto antes de excluir", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/global")

      view
      |> form("#global-exemption-form", global_subject: %{subject_type: "user", subject_id: ""})
      |> render_submit()

      assert render(view) =~ "Selecciona a quién excluir."
      assert Budgets.Exemptions.list_for_scope("global_daily") == []
    end
  end
end
