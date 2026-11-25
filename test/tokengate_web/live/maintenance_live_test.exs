defmodule TokengateWeb.SettingsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Tokengate.{Accounts, Logs, Providers}

  setup do
    # Oban runs in manual mode in tests, so a refresh job enqueued here never
    # drains. Clear leftovers so the busy-state assertions measure THIS test.
    Tokengate.Repo.delete_all(
      from(j in Oban.Job,
        where: j.worker == ^inspect(Tokengate.Providers.CatalogRefreshWorker)
      )
    )

    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "settings-#{u}@example.com",
        name: "Settings #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma textos en español de la página; el idioma por defecto
    # de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp insert_log(opts \\ []) do
    cost = Keyword.get(opts, :cost)
    {:ok, group} = Accounts.create_group(%{name: "Settings Group #{unique()}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "settings-owner-#{unique()}@example.com",
        name: "Owner",
        password: "password-secret-1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{unique()}", base_url: "http://localhost:1"})

    attrs = %{
      group_member_id: member.id,
      provider_id: provider.id,
      model_requested: "gpt-4o",
      prompt_tokens: 10,
      completion_tokens: 5
    }

    attrs = if cost, do: Map.put(attrs, :provider_cost_usd, cost), else: attrs

    attrs =
      if at = Keyword.get(opts, :inserted_at), do: Map.put(attrs, :inserted_at, at), else: attrs

    {:ok, _log} = Logs.log_request(attrs)
  end

  # Una partición VENCIDA (120 días) con un log dentro: el escenario que la
  # purga manual existe para resolver. DDL + sandbox: se revierte al terminar.
  defp old_partition_with_log! do
    day = Date.add(Date.utc_today(), -120)
    {:ok, _} = Tokengate.Logs.PartitionWorker.ensure_partition(day)
    insert_log(inserted_at: DateTime.new!(day, ~T[12:00:00], "Etc/UTC"))
    day
  end

  defp partition_exists?(name) do
    Tokengate.Repo.query!("SELECT to_regclass($1)", ["public." <> name]).rows != [[nil]]
  end

  describe "admin access" do
    test "danger zone renders", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, _view, html} = live(conn, ~p"/operations/maintenance")

      assert html =~ "Zona de peligro"
    end

    test "la zona de peligro queda al final, después de la de precaución", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      assert has_element?(view, "#caution-zone-card")
      assert has_element?(view, "#danger-zone-card")

      # Lo reversible vive en precaución; solo el borrado irreversible está en peligro.
      assert has_element?(view, "#caution-zone-card #reset-sticky-btn")

      # El borrado directo de logs se retiró: la única purga que queda es el
      # reset total, que ya los incluye.
      refute has_element?(view, "#reset-logs-btn")
      refute has_element?(view, "#confirm-reset-logs-btn")
      assert has_element?(view, "#danger-zone-card #reset-all-usage-btn")

      # El recálculo de costos históricos ya no se ofrece desde esta página.
      refute has_element?(view, "#backfill-costs-btn")
      refute has_element?(view, "#backfill-all-costs-btn")

      html = render(view)
      {caution_pos, _} = :binary.match(html, ~s(id="caution-zone-card"))
      {danger_pos, _} = :binary.match(html, ~s(id="danger-zone-card"))

      assert caution_pos < danger_pos
    end

    test "la actualización del catálogo vive en precaución y encola el job", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # Es reversible y no borra datos → precaución, nunca peligro.
      assert has_element?(view, "#caution-zone-card #catalog-refresh-card")
      refute has_element?(view, "#danger-zone-card #catalog-refresh-card")

      assert has_element?(view, "#refresh-catalog-btn")

      # La tarjeta reporta el estado del espejo.
      html = render(view)
      assert html =~ "models.dev"
      assert html =~ "activos"
    end

    test "el botón encola el refresh y queda en estado ocupado", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      refute Tokengate.Providers.CatalogRefreshWorker.in_flight?()

      html = view |> element("#refresh-catalog-btn") |> render_click()

      assert html =~ "Actualización del catálogo encolada"
      # El job queda en Oban (en test no se drena) y el botón se deshabilita:
      # un segundo click no puede encolar otra descarga.
      assert Tokengate.Providers.CatalogRefreshWorker.in_flight?()
      assert has_element?(view, "#refresh-catalog-btn[disabled]")
    end

    test "muestra el aviso de base URL movida bajo un proveedor en uso", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, _} =
        Tokengate.Providers.catalog_sync_state()
        |> Ecto.Changeset.change(
          warnings: [
            %{
              "key" => "fireworks-ai",
              "name" => "Fireworks AI",
              "reason" => "base_url_changed",
              "from" => "https://api.fireworks.ai/inference/v1",
              "to" => "https://api.fireworks.ai/inference/v2",
              "credentials" => 1
            }
          ]
        )
        |> Tokengate.Repo.update()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      assert has_element?(view, "#catalog-drift-warnings")
      html = render(view)
      assert html =~ "fireworks-ai"
      assert html =~ "cambió su base URL"
    end

    test "reset sticky sessions clears all sticky entries", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # Click reset sticky → confirmation modal appears
      view |> element("#reset-sticky-btn") |> render_click()
      # El contenedor es el .modal único: su id va en el div raíz.
      assert has_element?(view, "#confirm-sticky-reset-modal")
      assert has_element?(view, "#confirm-reset-sticky-btn")

      # Confirm reset
      view |> element("#confirm-reset-sticky-btn") |> render_click()

      assert render(view) =~ "Sticky sessions reiniciadas"
    end

    test "no hay purga de logs sin alcance; el reset total sigue borrando todo", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      insert_log()
      assert Logs.list_logs(%{limit: 1000}) |> length() > 0

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # La acción vieja "Delete log history" (sin alcance) no existe.
      refute has_element?(view, "#reset-logs-btn")
      refute has_element?(view, "#confirm-reset-logs-btn")

      # El borrado de TODO sigue ocurriendo dentro del reset total.
      view |> element("#reset-all-usage-btn") |> render_click()
      # El contenedor es el .modal único: su id va en el div raíz.
      assert has_element?(view, "#confirm-full-reset-modal")
      assert has_element?(view, "#confirm-reset-all-usage-btn")

      view |> element("#confirm-reset-all-usage-btn") |> render_click()

      assert render(view) =~ "Uso reseteado"
      assert Logs.list_logs(%{limit: 1000}) == []
    end

    # La purga por retención es otra cosa: NO borra todo, borra lo que ya pasó
    # la ventana de retención (la misma del cron nocturno), y lo dice con
    # números antes de tocar nada.
    test "purga por retención: preview al abrir y cancelar no borra", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      old_day = old_partition_with_log!()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      view |> element("#purge-expired-btn") |> render_click()

      assert has_element?(view, "#confirm-purge-modal")
      assert has_element?(view, "#purge-cutoff", Date.to_iso8601(Date.add(Date.utc_today(), -90)))
      # El preview lista la partición vencida por su nombre.
      assert has_element?(
               view,
               "#purge-preview",
               Tokengate.Logs.PartitionWorker.partition_name(old_day)
             )

      view |> element("#confirm-purge-modal button", "Cancelar") |> render_click()
      refute has_element?(view, "#confirm-purge-modal")
      assert partition_exists?(Tokengate.Logs.PartitionWorker.partition_name(old_day))
    end

    test "purga por retención: confirma, dropea lo vencido y audita", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      old_day = old_partition_with_log!()
      name = Tokengate.Logs.PartitionWorker.partition_name(old_day)

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      view |> element("#purge-expired-btn") |> render_click()
      view |> element("#confirm-purge-btn") |> render_click()

      refute partition_exists?(name)
      refute has_element?(view, "#confirm-purge-modal")
      assert render(view) =~ "Purgadas"

      audit =
        Tokengate.Repo.one(
          from(a in "audit_logs",
            where: a.action == "settings.purge_expired_logs",
            select: a.changes
          )
        )

      # El audit guarda los conteos reales: la partición del fixture está entre
      # las dropeadas (junto a la partición inicial hardcodeada de la migración,
      # también vencida en este entorno).
      assert %{"retention_days" => 90, "partitions_dropped" => dropped} = audit
      assert name in dropped
      assert Date.from_iso8601!(audit["cutoff_day"]) == Date.add(Date.utc_today(), -90)
    end

    test "la purga no toca los contadores de consumo ni el mes en curso", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      # Un log de HOY (mes y día en curso) además del vencido.
      insert_log(cost: Decimal.new("2.00"))
      _old_day = old_partition_with_log!()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      today_spend =
        Tokengate.Repo.one(
          from(c in "consumption_counters",
            where: not is_nil(c.user_id) and c.day == ^Date.utc_today(),
            select: sum(c.spend_micro)
          )
        )

      assert today_spend > 0

      view |> element("#purge-expired-btn") |> render_click()
      view |> element("#confirm-purge-btn") |> render_click()

      assert Tokengate.Repo.one(
               from(c in "consumption_counters",
                 where: not is_nil(c.user_id) and c.day == ^Date.utc_today(),
                 select: sum(c.spend_micro)
               )
             ) == today_spend
    end

    # Si el prune del rollup falló (o el cron dropeó el raw antes), lo único
    # vencido son filas de rollup. Con el botón mirando sólo particiones y
    # strays, la UI quedaba bloqueada justo cuando hacía falta reparar la
    # asimetría raw/rollup — y el guard de paridad caía a raw hasta el día
    # siguiente.
    test "el botón se habilita cuando sólo quedan filas de rollup vencidas", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      old_day = Date.add(Date.utc_today(), -120)

      Tokengate.Repo.query!(
        """
        INSERT INTO request_metrics_hourly (day, hour_utc, request_count, cost_micro)
        VALUES ($1, $2, 3, 1234)
        """,
        [old_day, DateTime.new!(old_day, ~T[10:00:00], "Etc/UTC")]
      )

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      view |> element("#purge-expired-btn") |> render_click()

      assert has_element?(view, "#confirm-purge-btn:not([disabled])")

      view |> element("#confirm-purge-btn") |> render_click()

      assert Tokengate.Repo.one(
               from(m in "request_metrics_hourly",
                 where: m.day == ^old_day,
                 select: count(m.id)
               )
             ) == 0
    end
  end

  describe "non-admin access" do
    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")

      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/maintenance")
    end
  end

  describe "zonas de la página" do
    test "renderiza el refresco de catálogo y las zonas de peligro", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      html = render(view)
      assert has_element?(view, "#catalog-refresh-card")
      assert has_element?(view, "#danger-zone-card", "Zona de peligro")
      assert has_element?(view, "#caution-zone-card", "Zona de precaución")
      assert String.contains?(html, "Mantenimiento")
    end

    test "reset_sticky_sessions records a non-nil entity_id in audit_logs", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      view |> element("#reset-sticky-btn") |> render_click()
      view |> element("#confirm-reset-sticky-btn") |> render_click()

      log =
        Tokengate.Repo.get_by!(
          Tokengate.Auditing.AuditLog,
          action: "settings.reset_sticky_sessions"
        )

      assert log.entity_id == "all"
    end
  end
end
