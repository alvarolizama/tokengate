defmodule TokengateWeb.UserStatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "ustats-#{u}@example.com",
        name: "U #{u}",
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

  defp fixture_group_member do
    {:ok, group} = Accounts.create_group(%{name: "Group #{unique()}"})

    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "tm-#{u}@example.com",
        name: "TM #{u}",
        password: "password-secret-#{u}1",
        global_role: "user"
      })

    {:ok, _member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    # Igual que `register/1`: este archivo afirma textos en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    {group, user}
  end

  defp fixture_user_with_memberships, do: fixture_group_member()

  # Rows of the recent-logs stream, empty-state row excluded (it always lives in
  # the markup, hidden by `only:table-row`).
  defp log_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#user-stats-logs tr:not(#user-stats-logs-empty)")
  end

  defp wait_stats_loaded(view, attempts \\ 200)

  defp wait_stats_loaded(view, attempts) when attempts > 0 do
    state = :sys.get_state(view.pid)

    case get_in(state, [Access.key(:socket), Access.key(:assigns), Access.key(:stats_loading)]) do
      false ->
        view

      _other ->
        Process.sleep(10)
        wait_stats_loaded(view, attempts - 1)
    end
  end

  defp wait_stats_loaded(_view, 0), do: raise("user stats async data never loaded")

  describe "auth" do
    test "unauthenticated visitors are redirected to /login", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, ~p"/stats/users/#{user.id}")
    end

    test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()
      %{user: regular, password: password} = register("user")
      conn = login(conn, regular, password)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/stats/users/#{user.id}")
    end
  end

  describe "render" do
    test "admin sees the consolidated header (email + memberships count)", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/stats/users/#{user.id}")

      assert html =~ user.email
      assert html =~ "1 membresía"
    end

    test "admin sees the member's logs across all their memberships", %{conn: conn} do
      {group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_group_members_for_user(user.id))

      {:ok, _log1} =
        Logs.log_request(%{
          group_member_id: member.id,
          group_id: group.id,
          user_email: user.email,
          model_requested: "gpt-4o-stats",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.001"),
          latency_ms: 300
        })

      {:ok, _log2} =
        Logs.log_request(%{
          group_member_id: member.id,
          group_id: group.id,
          user_email: user.email,
          model_requested: "gpt-4o-stats",
          status_code: 503,
          prompt_tokens: 0,
          completion_tokens: 0,
          provider_cost_usd: Decimal.new("0"),
          latency_ms: 100
        })

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)
      html = render(view)

      assert html =~ "gpt-4o-stats"
      assert html =~ "200"
      assert html =~ "503"
    end

    test "admin sees the consolidated total cost across memberships", %{conn: conn} do
      {group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_group_members_for_user(user.id))

      Logs.log_request(%{
        group_member_id: member.id,
        group_id: group.id,
        user_email: user.email,
        model_requested: "gpt-4o",
        status_code: 200,
        prompt_tokens: 1000,
        completion_tokens: 500,
        provider_cost_usd: Decimal.new("0.123"),
        latency_ms: 300
      })

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      # Cost card renders with the canonical period label and dollar amount.
      assert has_element?(view, "#user-kpi-cost", "Costo")
      assert has_element?(view, "#user-kpi-cost", "$0.123")
      assert has_element?(view, "#period-selector")
      assert has_element?(view, "#period-week.btn-primary")
    end

    test "period selector switches window via ?period= and scopes summary", %{conn: conn} do
      {group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_group_members_for_user(user.id))
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      ten_days_ago = DateTime.add(now, -10 * 86_400, :second)

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          group_id: group.id,
          user_email: user.email,
          model_requested: "old-period-model",
          status_code: 200,
          prompt_tokens: 200,
          completion_tokens: 100,
          provider_cost_usd: Decimal.new("0.500"),
          latency_ms: 150,
          inserted_at: ten_days_ago
        })

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      # Default is "week": 10-day-old log is outside the week window.
      assert has_element?(view, "#period-week.btn-primary")
      assert has_element?(view, "#user-kpi-requests", "0")

      # Switching to 30d includes the 10-day-old log.
      view |> element("#period-30d") |> render_click()
      wait_stats_loaded(view)

      assert has_element?(view, "#period-30d.btn-primary")
      assert has_element?(view, "#user-kpi-requests", "1")
      assert has_element?(view, "#user-kpi-cost", "$0.5")
    end

    test "shows load error banner when an async load exits", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)
      refute has_element?(view, "#user-stats-load-error")

      {:noreply, err_socket} =
        TokengateWeb.UserStatsLive.handle_async(
          :user_summary,
          {:exit, :boom},
          :sys.get_state(view.pid).socket
        )

      assert err_socket.assigns.load_error == true
      assert err_socket.assigns.stats_loading == false
    end

    test "la membresía única enlaza a su grupo", %{conn: conn} do
      {group, user} = fixture_user_with_memberships()

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")

      # Un usuario pertenece a UNA sola sub: su detalle lista esa membresía, y
      # el nombre del perfil de límites lleva a su detalle (sin el enlace quedaba como
      # texto muerto).
      assert has_element?(
               view,
               "#membership-group-#{group.id}[href*='/stats/profiles/#{group.id}']",
               group.name
             )
    end
  end

  describe "back-link icon" do
    test "users_live has a stats link for every user", %{conn: conn} do
      {_group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/access/users")
      assert html =~ ~s(id="stats-#{user.id}")
    end
  end

  describe "filtros (F6/P15)" do
    test "un user_id inexistente o no-UUID redirige en vez de romper el mount", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      assert {:error, {:live_redirect, %{to: "/stats/users"}}} =
               live(conn, ~p"/stats/users/#{Ecto.UUID.generate()}")

      assert {:error, {:live_redirect, %{to: "/stats/users"}}} =
               live(conn, ~p"/stats/users/not-a-uuid")
    end

    test "Desde/Hasta parsean a datetime: una fecha inválida se ignora, no tumba el socket", %{
      conn: conn
    } do
      {group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_group_members_for_user(user.id))
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old = DateTime.add(now, -10 * 86_400, :second)

      for {name, inserted_at} <- [{"reciente-model", now}, {"viejo-model", old}] do
        {:ok, _} =
          Logs.log_request(%{
            group_member_id: member.id,
            group_id: group.id,
            user_email: user.email,
            model_requested: name,
            status_code: 200,
            prompt_tokens: 10,
            completion_tokens: 5,
            provider_cost_usd: Decimal.new("0.001"),
            latency_ms: 100,
            inserted_at: inserted_at
          })
      end

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)
      assert Enum.count(log_rows(view)) == 2

      from = Date.add(Date.utc_today(), -5) |> Date.to_string()

      view
      |> form("#user-stats-filter-form", %{"filter" => %{"from" => from}})
      |> render_change()

      wait_stats_loaded(view)
      assert Enum.count(log_rows(view)) == 1
      assert render(view) =~ "reciente-model"

      # A value that is not a date drops the filter instead of reaching Ecto as
      # a string (the old CastError killed the LiveView).
      view
      |> form("#user-stats-filter-form", %{"filter" => %{"from" => "no-es-fecha"}})
      |> render_change()

      wait_stats_loaded(view)
      assert Enum.count(log_rows(view)) == 2
    end

    test "un payload de filtro sin el mapa anidado no rompe", %{conn: conn} do
      {_group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      render_change(view, "filter", %{"filter" => "wat"})
      wait_stats_loaded(view)
      html = render(view)

      assert html =~ user.email
      assert has_element?(view, "#user-stats-filter-form")
    end

    test "DST transition dates in local timezone do not crash", %{conn: conn} do
      {_group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      {:ok, admin} = Accounts.update_user_timezone(admin, "America/New_York")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      view
      |> form("#user-stats-filter-form", %{
        "filter" => %{"from" => "2026-03-08", "to" => "2026-03-08"}
      })
      |> render_change()

      wait_stats_loaded(view)
      assert has_element?(view, "#user-stats-filter-form")
    end

    test "live stream caps rendered logs at page size when many :new_log broadcasts arrive", %{
      conn: conn
    } do
      {_group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..55 do
        send(
          view.pid,
          {:new_log,
           %Tokengate.Logs.RequestLog{
             id: Ecto.UUID.generate(),
             user_id: user.id,
             model_requested: "stream-cap-#{i}",
             status_code: 200,
             prompt_tokens: 1,
             completion_tokens: 1,
             provider_cost_usd: Decimal.new("0.001"),
             latency_ms: 10,
             inserted_at: DateTime.add(now, i, :second)
           }}
        )
      end

      _ = render(view)
      assert Enum.count(log_rows(view)) == 50
    end
  end

  # `:user_series` is a third async task (the trend), independent of the
  # `stats_loading` flag the summary/logs tasks drive: wait for its card
  # instead of guessing.
  defp wait_for_element(view, selector, attempts \\ 200)

  defp wait_for_element(view, selector, attempts) when attempts > 0 do
    if has_element?(view, selector) do
      view
    else
      Process.sleep(10)
      wait_for_element(view, selector, attempts - 1)
    end
  end

  defp wait_for_element(_view, selector, 0),
    do: raise("element #{selector} never rendered")

  describe "FinOps per user (S4)" do
    test "unit economics, waste and cache posture are derived from the single pass", %{
      conn: conn
    } do
      {group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_group_members_for_user(user.id))

      # Tráfico servido: 1M prompt (400k cacheados) / 500k completion, $2.
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          group_id: group.id,
          user_email: user.email,
          model_requested: "gpt-4o-finops",
          status_code: 200,
          prompt_tokens: 1_000_000,
          completion_tokens: 500_000,
          cache_read_tokens: 400_000,
          prompt_tokens_saved_est: 12_345,
          provider_cost_usd: Decimal.new("2.000000"),
          latency_ms: 1_000,
          think: true,
          cache_hit: true
        })

      # Desperdicio: un 5xx que costó $0.5 sin tokens.
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          group_id: group.id,
          user_email: user.email,
          model_requested: "gpt-4o-finops",
          status_code: 500,
          prompt_tokens: 0,
          completion_tokens: 0,
          provider_cost_usd: Decimal.new("0.500000"),
          latency_ms: 100
        })

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)
      wait_for_element(view, "#user-finops-trend")

      # $2.5 de gasto / 2 requests servidas.
      assert has_element?(view, "#user-finops-cpr", "$1.25")
      # $2.5 sobre 1.5M tokens.
      assert has_element?(view, "#user-finops-per-1m", "$1.6667")
      # 500k out / 1M in.
      assert has_element?(view, "#user-finops-out-in", "0.5x")
      # 400k / 1M de prompt.
      assert has_element?(view, "#user-finops-cache", "40.0%")
      # Tokens ahorrados por el caché local (12.345 → 12.3K).
      assert has_element?(view, "#user-finops-local-cache", "12.3K")
      # $0.5 de $2.5 = 20% del gasto.
      assert has_element?(view, "#user-finops-error-waste", "20.0%")
      # La request con `think` costó $2 de $2.5 = 80%.
      assert has_element?(view, "#user-finops-thinking", "80.0%")
      # Sin top-ups en la ventana.
      assert has_element?(view, "#user-finops-topups", "$0.00")

      # Burn y proyección (la ventana por defecto es la semana).
      assert has_element?(view, "#user-finops-burn-day", "promedio por día")
      assert has_element?(view, "#user-finops-projection")
      assert has_element?(view, "#user-finops-trend")
    end

    test "the trend chart is empty (and hidden) when the period has no traffic", %{conn: conn} do
      {_group, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/users/#{user.id}")
      wait_stats_loaded(view)

      assert has_element?(view, "#user-finops")
      refute has_element?(view, "#user-finops-trend")
    end
  end

  describe "Logs.user_stats/2 (single-pass aggregate)" do
    test "keeps the member_stats shape and adds the FinOps block" do
      {group, user} = fixture_user_with_memberships()
      member = hd(Accounts.list_group_members_for_user(user.id))
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      from = DateTime.add(now, -3_600, :second)

      for {model, status, cost} <- [{"keep-a", 200, "0.001"}, {"keep-b", 503, "0.002"}] do
        {:ok, _} =
          Logs.log_request(%{
            group_member_id: member.id,
            group_id: group.id,
            user_email: user.email,
            model_requested: model,
            status_code: status,
            prompt_tokens: 10,
            completion_tokens: 5,
            provider_cost_usd: Decimal.new(cost),
            latency_ms: 100,
            inserted_at: now
          })
      end

      stats = Logs.user_stats(user.id, from: from, to: now)

      # El shape de `member_stats/2` se conserva clave por clave...
      for key <- [
            :total_cost_usd,
            :total_prompt_tokens,
            :total_completion_tokens,
            :total_cache_read_tokens,
            :total_cache_creation_tokens,
            :request_count,
            :error_count,
            :total_latency_ms,
            :latency_count,
            :ttft_count,
            :avg_latency_ms,
            :avg_ttft_ms,
            :avg_tps,
            :status_breakdown,
            :top_models,
            :last_request_at,
            :realtime_5min,
            :finops
          ],
          do: assert(Map.has_key?(stats, key))

      assert stats.request_count == 2
      assert stats.status_breakdown == %{"2xx" => 1, "4xx" => 0, "5xx" => 1}
      assert stats.error_count == 1
      assert stats.last_request_at == now
      assert Decimal.compare(stats.total_cost_usd, Decimal.new("0.003")) == :eq

      assert stats.top_models |> Enum.map(& &1.model_requested) |> Enum.sort() == [
               "keep-a",
               "keep-b"
             ]

      # ...y el bloque FinOps suma lo mismo desde las mismas filas.
      assert stats.finops.requests == 2
      assert Decimal.compare(stats.finops.cost_usd, Decimal.new("0.003")) == :eq
      assert stats.finops.error_requests == 1
      assert Decimal.compare(stats.finops.error_cost_usd, Decimal.new("0.002")) == :eq
      assert stats.finops.think_requests == 0
    end
  end
end
