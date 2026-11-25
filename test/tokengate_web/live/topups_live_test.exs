defmodule TokengateWeb.TopupsLiveTest do
  @moduledoc """
  Tests de la página de Top-ups — la **única** página de crédito del modelo
  nuevo: crédito extra de un solo uso por usuario **o** servicio, con
  expiración opcional, consumo medido contra los logs y archivo de vencidos y
  agotados.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs}
  alias Tokengate.Credits.Topups

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "topups-#{u}@example.com",
        name: "Topups #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma textos en español; el idioma por defecto de la UI es
    # inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp user_fixture do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "bono-#{u}@example.com",
        name: "Bono #{u}",
        password: "ValidPassword123"
      })

    user
  end

  defp service_fixture do
    {:ok, service} = Accounts.create_service(%{"name" => "svc-#{unique()}"})
    service
  end

  # Consumo asentado contra un top-up: es lo que la columna Consumo mide.
  defp consume(topup, cost) do
    u = unique()

    {:ok, owner} =
      Accounts.register_user(%{
        email: "consume-#{u}@example.com",
        name: "C #{u}",
        password: "ValidPassword123"
      })

    {:ok, group} = Accounts.create_group(%{"name" => "G#{u}", "unlimited_spend" => true})
    {:ok, member} = Accounts.create_group_member(%{"user_id" => owner.id, "group_id" => group.id})

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "gpt-4",
        provider_cost_usd: cost,
        credit_topup_id: topup.id
      })

    :ok
  end

  defp topup_fixture(attrs) do
    {:ok, topup} = Topups.create(attrs)
    topup
  end

  describe "access" do
    test "renders the top-ups list for admin", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      # Sin top-ups el componente `.table` rinde sólo el empty-state: el id del
      # tbody aparece en cuanto hay filas (ver el resto de tests).
      assert has_element?(view, "#topups-empty")
      assert has_element?(view, "#topups-empty", "No hay top-ups")
      assert has_element?(view, "#new-topup-btn")
      assert render(view) =~ "Top-ups"
      # La página ya no habla de suscripciones.
      refute render(view) =~ "Suscrip"
    end

    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")
      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/budget/topups")
    end
  end

  describe "listado" do
    test "muestra el dueño (usuario o servicio), el monto y la etiqueta", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      service = service_fixture()

      user_topup =
        topup_fixture(%{
          "user_id" => user.id,
          "amount_usd" => "10.00",
          "label" => "para-usuario"
        })

      topup_fixture(%{
        "service_id" => service.id,
        "amount_usd" => "20.00",
        "label" => "para-servicio"
      })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      # Contrato `.table`: un tbody `#topups` con los headers del listado.
      assert has_element?(view, "#topups")
      assert has_element?(view, "table th", "Dueño")
      assert has_element?(view, "table th", "Monto")
      assert has_element?(view, "table th", "Consumo")
      assert has_element?(view, "table th", "Estado")
      assert has_element?(view, "#edit-topup-#{user_topup.id}")

      html = render(view)
      assert html =~ user.email
      assert html =~ service.name
      assert html =~ "$10.00"
      assert html =~ "$20.00"
    end

    # N+1: el consumo de cada fila se lee desde `topup_consumption_counters`
    # en una sola consulta por carga (sin escanear `request_logs`), y buscar/
    # ordenar/archivar operan en memoria con cero queries.
    test "el consumo de la lista se resuelve en una sola query", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      for _ <- 1..4 do
        topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
        consume(topup, "1.00")
      end

      ref = make_ref()
      parent = self()
      conn = login(conn, admin, pass)

      :telemetry.attach(
        {__MODULE__, ref},
        [:tokengate, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "topup_consumption_counters" do
            send(parent, {:counters_query, ref})
          end

          if meta.source in ["credit_topups", "topup_consumption_counters", "request_logs"] do
            send(parent, {:topup_list_query, ref, meta.source})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      # Static + connected mount: 1 counter query each, 0 request_logs scans.
      assert_received {:counters_query, ^ref}
      assert_received {:counters_query, ^ref}
      refute_received {:counters_query, ^ref}
      refute_received {:topup_list_query, ^ref, "request_logs"}

      # Drain mount notifications, then verify search/sort run purely in memory.
      flush_topup_queries(ref)

      view |> element("#topup-search-form") |> render_change(%{"q" => user.email})
      view |> element("th button[phx-value-field='amount']") |> render_click()

      refute_received {:topup_list_query, ^ref, _}
      assert render(view) =~ "$1.00"
    end

    defp flush_topup_queries(ref) do
      receive do
        {:topup_list_query, ^ref, _} -> flush_topup_queries(ref)
      after
        0 -> :ok
      end
    end

    test "muestra lo consumido del top-up medido contra los logs", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      consume(topup, "2.50")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      assert has_element?(view, "#topup-usage-#{topup.id}")
      assert render(view) =~ "$2.50"
    end
  end

  describe "top-ups CRUD" do
    test "crea un top-up de usuario con monto y expiración", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      # El contenedor es el .modal único: su id va en el div raíz.
      assert has_element?(view, "#topup-form-modal")

      html =
        view
        |> form("#topup-form", %{
          "topup" => %{"amount_usd" => "15.50", "label" => "manual", "expires_in_days" => "7"}
        })
        |> render_submit()

      assert html =~ "Top-up guardado."

      assert [topup] = Topups.list_for_user(user.id)
      assert Decimal.equal?(topup.amount_usd, Decimal.new("15.50"))
      assert topup.label == "manual"
      assert topup.expires_in_days == 7
      assert topup.expires_at
    end

    test "crea un top-up de servicio (dueño servicio)", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      service = service_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#owner-kind-service") |> render_click()
      view |> element("#select-owner-#{service.id}") |> render_click()

      view
      |> form("#topup-form", %{"topup" => %{"amount_usd" => "30.00", "expires_in_days" => ""}})
      |> render_submit()

      assert [topup] = Topups.list_for_service(service.id)
      assert topup.service_id == service.id
      assert topup.user_id == nil
      assert Decimal.equal?(topup.amount_usd, Decimal.new("30.00"))
      # Sin expiración = nunca vence.
      assert topup.expires_at == nil
    end

    test "sin expiración el top-up nunca vence", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      view
      |> form("#topup-form", %{"topup" => %{"amount_usd" => "5.00", "expires_in_days" => ""}})
      |> render_submit()

      assert [topup] = Topups.list_for_user(user.id)
      assert topup.expires_at == nil
      assert Topups.grants_credit?(topup)
    end

    # F17: the owner search declares `phx-change` on the input itself, so
    # LiveView ships the typed value under "value" (the `name` only travels as
    # `_target`). The handler expected %{"q" => _} and the view died on the
    # first keystroke.
    test "escribir en el buscador de dueño filtra sin matar la LiveView", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()

      html =
        view
        |> element("#topup-owner-search")
        |> render_change(%{"value" => user.email})

      assert html =~ user.email
      assert has_element?(view, "#select-owner-#{user.id}")

      html =
        view
        |> element("#topup-owner-search")
        |> render_change(%{"value" => "sin-coincidencias-#{unique()}"})

      refute html =~ user.email
      assert html =~ "Sin coincidencias"

      # The view is still alive: the owner picker keeps responding.
      view |> element("#owner-kind-service") |> render_click()
      assert has_element?(view, "#topup-owner-search")
    end

    # F8: two submits of the same form (a double click, or one queued behind
    # the other) used to create TWO top-ups. The one-shot token lives in the
    # form and is consumed by the first save.
    test "un doble submit crea UN solo top-up", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      token_html = view |> element("#topup-idempotency-key") |> render()
      [_, token] = Regex.run(~r/value="([^"]+)"/, token_html)

      payload = %{"topup" => %{"amount_usd" => "10.00"}, "idempotency_key" => token}

      html = render_submit(view, "save_topup", payload)
      assert html =~ "Top-up guardado."

      # Second submit with the SAME token: ignored.
      render_submit(view, "save_topup", payload)

      assert [topup] = Topups.list_for_user(user.id)
      assert Decimal.equal?(topup.amount_usd, Decimal.new("10.00"))
    end

    test "un submit sin el token del form (forjado) no escribe nada", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      render_submit(view, "save_topup", %{
        "topup" => %{"amount_usd" => "99.00"},
        "idempotency_key" => Ecto.UUID.generate()
      })

      assert Topups.list_for_user(user.id) == []
    end
  end

  describe "acciones" do
    test "desactivar deja de otorgar y reactivar vuelve a otorgar", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      assert Topups.grants_credit?(topup)

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      assert render(view) =~ "Top-up desactivado" == false
      view |> element("#toggle-topup-status-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up desactivado"
      refute Topups.grants_credit?(Topups.get_topup!(topup.id))

      view |> element("#toggle-topup-status-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up reactivado"
      assert Topups.grants_credit?(Topups.get_topup!(topup.id))
    end

    test "revocar deja de otorgar sin borrar el consumo", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      consume(topup, "3.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#revoke-topup-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up revocado."

      reloaded = Topups.get_topup!(topup.id)
      assert reloaded.status == "revoked"
      refute Topups.grants_credit?(reloaded)
      # Lo ya consumido vive en los logs y se sigue midiendo.
      assert Decimal.equal?(Topups.consumed_usd(reloaded), Decimal.new("3.000000"))
    end

    # F6: `get_topup!(id)` on a client non-UUID raised Ecto.Query.CastError and
    # killed the LiveView; a missing one raised NoResultsError.
    test "un id de cliente no-UUID o inexistente no revienta la vista", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      assert render_hook(view, "toggle_topup_status", %{"id" => "no-es-uuid"}) =~
               "Top-up no encontrado"

      assert render_hook(view, "revoke_topup", %{"id" => "no-es-uuid"}) =~ "Top-up no encontrado"
      assert render_hook(view, "edit_topup", %{"id" => "no-es-uuid"}) =~ "Top-up no encontrado"

      assert render_hook(view, "toggle_topup_status", %{"id" => Ecto.UUID.generate()}) =~
               "Top-up no encontrado"

      # A forged owner neither touches the DB nor selects anybody.
      render_hook(view, "select_owner", %{"id" => "no-es-uuid"})
      refute has_element?(view, "#selected-owner")

      render_hook(view, "select_owner", %{"id" => Ecto.UUID.generate()})
      refute has_element?(view, "#selected-owner")

      # The view and the real top-up are untouched.
      assert Topups.get_topup!(topup.id).status == "active"
      assert has_element?(view, "#toggle-topup-status-#{topup.id}")
    end
  end

  describe "auto-archived top-ups" do
    test "oculta los agotados (remanente 0) y el toggle los revela", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "1.00"})
      consume(topup, "1.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      refute has_element?(view, "#edit-topup-#{topup.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{topup.id}")

      view |> element("#toggle-archived-btn") |> render_click()
      refute has_element?(view, "#edit-topup-#{topup.id}")
    end

    test "oculta los vencidos y el toggle los revela", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      topup =
        topup_fixture(%{
          "user_id" => user.id,
          "amount_usd" => "50.00",
          "expires_in_days" => 1,
          "expires_at" => DateTime.add(DateTime.utc_now(), -1, :day)
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      refute has_element?(view, "#edit-topup-#{topup.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{topup.id}")
      assert render(view) =~ "Vencido"
    end

    test "un top-up activo nunca se archiva", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "20.00"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      assert has_element?(view, "#edit-topup-#{topup.id}")
      refute has_element?(view, "#toggle-archived-btn")
    end

    test "select_owner limpia el buscador y edit_topup muestra el dueño bloqueado", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "25.00"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#topup-owner-search") |> render_change(%{"value" => user.email})
      html = view |> element("#select-owner-#{user.id}") |> render_click()

      assert has_element?(view, "#selected-owner", user.email)
      refute html =~ "Sin coincidencias"

      view |> element("#edit-topup-#{topup.id}") |> render_click()
      assert has_element?(view, "#selected-owner", user.email)
      refute has_element?(view, "#owner-kind-service")
      refute has_element?(view, "#topup-owner-search")

      # Forged owner_kind event during edit cannot drop selected_owner.
      render_click(view, "owner_kind", %{"kind" => "service"})
      assert has_element?(view, "#selected-owner", user.email)
    end

    test "lee consumo durable desde topup_consumption_counters sin depender de logs", %{
      conn: conn
    } do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})

      Tokengate.Repo.insert!(%Tokengate.Metrics.TopupConsumptionCounter{
        topup_id: topup.id,
        consumed_micro: 4_250_000
      })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/budget/topups")

      assert has_element?(view, "#topup-usage-#{topup.id}", "$4.25")
    end
  end
end
