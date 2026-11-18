defmodule TokengateWeb.CalculatorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "calc-#{u}@example.com",
        name: "Calc #{u}",
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

  # ---------------------------------------------------------------------------
  # Fixtures (patrón de test/tokengate/providers_test.exs)
  # ---------------------------------------------------------------------------

  defp model_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "calc-model-#{unique()}",
        context_window: 128_000,
        model_type: "llm"
      })

    {:ok, model} = Providers.create_model(attrs)
    model
  end

  defp provider_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Calc Prov #{unique()}",
        base_url: "https://api.calc.test",
        status: "active"
      })

    {:ok, provider} = Providers.create_provider(attrs)
    provider
  end

  defp credential_fixture(provider, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        provider_id: provider.id,
        name: "calc-key-#{unique()}",
        api_key_encrypted: "sk-calc-#{unique()}",
        status: "active"
      })

    {:ok, credential} = Providers.create_credential(attrs)
    credential
  end

  defp lane_fixture(model, credential, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "upstream-#{unique()}",
        priority: 0,
        enabled: true
      })

    {:ok, lane} = Providers.create_model_provider(attrs)
    lane
  end

  # Lane montado en un pool de N keys del mismo provider.
  defp pool_lane_fixture(model, provider, credentials, attrs \\ %{}) do
    {:ok, pool} = Providers.create_pool(provider, %{name: "pool-#{unique()}"})

    Enum.each(credentials, fn credential ->
      {:ok, _member} = Providers.add_pool_member(pool, credential)
    end)

    attrs =
      Enum.into(attrs, %{
        model_id: model.id,
        pool_id: pool.id,
        provider_model: "pool-upstream-#{unique()}",
        priority: 0,
        enabled: true
      })

    {:ok, lane} = Providers.create_model_provider(attrs)
    {lane, pool}
  end

  # ---------------------------------------------------------------------------
  # Log seeding (patrón de test/tokengate_web/live/stats_charts_test.exs)
  # ---------------------------------------------------------------------------

  defp group_member_fixture do
    u = unique()
    {:ok, group} = Accounts.create_group(%{name: "Calc Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "calc-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})
    member
  end

  defp log(member, model, attrs) do
    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_id: model.id,
        model_provider_id: Map.get(attrs, :lane_id),
        credential_id: Map.get(attrs, :credential_id),
        model_requested: model.name,
        model_responded: model.name,
        agent_type: "api",
        status_code: 200,
        prompt_tokens: Map.get(attrs, :prompt_tokens, 1_000),
        completion_tokens: Map.get(attrs, :completion_tokens, 500),
        cache_read_tokens: Map.get(attrs, :cache_read_tokens, 0),
        cache_creation_tokens: Map.get(attrs, :cache_creation_tokens, 0),
        provider_cost_usd: Map.fetch!(attrs, :cost),
        latency_ms: 42,
        streaming: false,
        inserted_at: inserted_at()
      })

    :ok
  end

  defp inserted_at do
    DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp change(view, params) do
    view |> form("#calculator-form", params) |> render_change()
  end

  defp real_text(view) do
    view |> element("#calc-real") |> render()
  end

  defp estimated_text(view) do
    view |> element("#calc-estimated") |> render()
  end

  test "admin sees calculator page with form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/calculator")

    assert html =~ "Calculadora de Costos"
    assert html =~ "Precios custom"
    # Input groups: label + $ prefix + /1M suffix per price
    assert html =~ ~s(for="cost-input")
    assert html =~ "Entrada"
    assert html =~ "Cache"
    assert html =~ "Salida"
    assert html =~ "/1M"
    # El lane y la escritura de cache existen desde el mount
    assert has_element?(view, "#lane-select")
    assert has_element?(view, "#cost-cache-write")
    assert has_element?(view, ~s(#lane-select option[value=""]))
    _ = view
  end

  test "regular user is redirected from calculator", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/calculator")
    assert to =~ "/dashboard"
  end

  test "selecting a model renders the real and custom estimate cards", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{
        model_id: model_.id,
        cost_input: "3.00",
        cost_cache: "0.30",
        cost_output: "15.00"
      })
      |> render_change()

    # Ambas comparativas renderizan aunque no haya tráfico en el periodo.
    assert has_element?(view, "#calc-real")
    assert has_element?(view, "#calc-estimated")

    # Los inputs custom conservan lo enviado.
    assert html =~ ~s(value="3.00")
    assert html =~ ~s(value="15.00")
  end

  test "the market estimate is gone from the calculator", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{model_id: model_.id})
      |> render_change()

    refute has_element?(view, "#calc-market")
    refute has_element?(view, "#use-market-prices")
    refute html =~ "Estimado Mercado"
    refute html =~ "Mercado:"
  end

  # ---------------------------------------------------------------------------
  # (a) El lane precarga sus cuatro precios y el sufijo de la unidad
  # ---------------------------------------------------------------------------

  test "choosing a lane prefills its four prices and the /1M suffix", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "gpt-lane-#{unique()}",
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "3.50",
        cache_cost_per_million: "0.35",
        cache_write_cost_per_million: "4.20",
        output_cost_per_million: "14.00"
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    # The lane select is populated when the model is picked (with its label).
    html = change(view, %{model_id: model_.id})
    assert html =~ lane.provider_model
    assert html =~ "(P0)"
    assert html =~ "/1M"

    # Picking the lane brings its four prices.
    html = change(view, %{model_id: model_.id, lane_id: lane.id})

    assert html =~ ~s(value="3.50")
    assert html =~ ~s(value="0.35")
    assert html =~ ~s(value="4.20")
    assert html =~ ~s(value="14.00")
    assert html =~ "/1M"
    refute has_element?(view, "#lane-unit-notice")
  end

  test "a per_1k_tokens lane keeps its prices and labels them /1K", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "cheap-lane-#{unique()}",
        pricing_unit: "per_1k_tokens",
        input_cost_per_million: "0.0035",
        cache_cost_per_million: "0.00035",
        cache_write_cost_per_million: "0.0042",
        output_cost_per_million: "0.014"
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    html = change(view, %{model_id: model_.id, lane_id: lane.id})

    assert html =~ "/1K"

    # 1K prices are fractions of a cent: rounding them to cents would zero the
    # estimate, so the prefill keeps the lane's precision.
    assert has_element?(view, "#cost-input[value='0.0035']")
    assert has_element?(view, "#cost-cache[value='0.00035']")
    assert has_element?(view, "#cost-cache-write[value='0.0042']")
    assert has_element?(view, "#cost-output[value='0.014']")
  end

  test "the estimate adds the cache write term", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)
    member = group_member_fixture()

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "math-lane-#{unique()}",
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "2.00",
        cache_cost_per_million: "0.20",
        cache_write_cost_per_million: "2.50",
        output_cost_per_million: "10.00"
      })

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "10.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000,
      cache_read_tokens: 0,
      cache_creation_tokens: 1_000_000
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    # 1M × 2.00 + 0 × 0.20 + 1M × 2.50 + 1M × 10.00 = $14.50. Without the
    # additive cache-write term the estimate would be $12.00.
    assert estimated_text(view) =~ "$14.50"
  end

  test "a per_1k_tokens lane divides the estimate by 1000", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)
    member = group_member_fixture()

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "divisor-lane-#{unique()}",
        pricing_unit: "per_1k_tokens",
        input_cost_per_million: "0.002",
        cache_cost_per_million: "0.0002",
        cache_write_cost_per_million: "0.0025",
        output_cost_per_million: "0.010"
      })

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "12.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    # (1M × 0.002 + 1M × 0.010) / 1000 = $12.00; the /1M divisor would give
    # $12,000, so this pins the lane unit.
    assert estimated_text(view) =~ "$12.00"
  end

  test "clearing the lane resets the prices to the defaults", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        input_cost_per_million: "3.50",
        cache_cost_per_million: "0.35",
        cache_write_cost_per_million: "4.20",
        output_cost_per_million: "14.00"
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})
    assert has_element?(view, "#cost-input[value='3.50']")

    change(view, %{model_id: model_.id, lane_id: ""})

    # Prices from a lane that is no longer selected must not linger.
    assert has_element?(view, "#cost-input[value='3.00']")
    assert has_element?(view, "#cost-cache[value='0.30']")
    assert has_element?(view, "#cost-cache-write[value='0.00']")
    assert has_element?(view, "#cost-output[value='15.00']")
  end

  # ---------------------------------------------------------------------------
  # (b) Lo tecleado sobrevive al siguiente render_change
  # ---------------------------------------------------------------------------

  test "a typed price survives the next render_change", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        input_cost_per_million: "3.50",
        cache_cost_per_million: "0.35",
        cache_write_cost_per_million: "4.20",
        output_cost_per_million: "14.00"
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    # Lo tecleado se envía en un change propio (el navegador manda un input
    # por evento) y queda en los assigns.
    html =
      change(view, %{model_id: model_.id, lane_id: lane.id, cost_input: "9.99"})

    assert html =~ ~s(value="9.99")

    # Segundo cambio sin tocar modelo ni lane: lo tecleado se conserva.
    html = change(view, %{model_id: model_.id, lane_id: lane.id})
    assert html =~ ~s(value="9.99")
    # …y los otros tres siguen siendo los del lane.
    assert html =~ ~s(value="0.35")
    assert html =~ ~s(value="4.20")
    assert html =~ ~s(value="14.00")
  end

  # ---------------------------------------------------------------------------
  # (c) El real de un lane excluye los otros lanes del modelo
  # ---------------------------------------------------------------------------

  test "the lane-filtered real excludes the other lanes", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()

    provider_a = provider_fixture()
    key_a = credential_fixture(provider_a)
    lane_a = lane_fixture(model_, key_a, %{provider_model: "lane-a-#{unique()}"})

    provider_b = provider_fixture()
    key_b = credential_fixture(provider_b)
    lane_b = lane_fixture(model_, key_b, %{provider_model: "lane-b-#{unique()}"})

    log(member, model_, %{lane_id: lane_a.id, credential_id: key_a.id, cost: "1.00"})
    log(member, model_, %{lane_id: lane_b.id, credential_id: key_b.id, cost: "5.00"})

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane_a.id})
    assert real_text(view) =~ "$1.00"

    change(view, %{model_id: model_.id, lane_id: lane_b.id})
    assert real_text(view) =~ "$5.00"
  end

  # ---------------------------------------------------------------------------
  # (d) Lane de pool: select de keys y el real baja al elegir una
  # ---------------------------------------------------------------------------

  test "a pool lane lists its keys and picking one narrows the real", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    member = group_member_fixture()

    key_a = credential_fixture(provider, %{name: "pool-key-a"})
    key_b = credential_fixture(provider, %{name: "pool-key-b"})
    {lane, _pool} = pool_lane_fixture(model_, provider, [key_a, key_b])

    log(member, model_, %{lane_id: lane.id, credential_id: key_a.id, cost: "2.00"})
    log(member, model_, %{lane_id: lane.id, credential_id: key_b.id, cost: "3.00"})

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    html = change(view, %{model_id: model_.id})
    assert html =~ "Pool"
    assert html =~ "(2 keys)"

    change(view, %{model_id: model_.id, lane_id: lane.id})

    assert has_element?(view, "#credential-select")
    assert has_element?(view, ~s(#credential-select option[value=""]))
    assert has_element?(view, "#credential-select option[value='#{key_a.id}']")
    assert has_element?(view, "#credential-select option[value='#{key_b.id}']")
    assert render(view) =~ "pool-key-a"
    assert render(view) =~ "pool-key-b"
    assert real_text(view) =~ "$5.00"

    # Una key del pool acota el real a SU tráfico.
    change(view, %{
      model_id: model_.id,
      lane_id: lane.id,
      credential_id: key_a.id
    })

    assert real_text(view) =~ "$2.00"
  end

  # ---------------------------------------------------------------------------
  # (e) Sin lane: la suma de todos los lanes del modelo
  # ---------------------------------------------------------------------------

  test "without a lane the real sums every lane of the model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()

    provider_a = provider_fixture()
    key_a = credential_fixture(provider_a)
    lane_a = lane_fixture(model_, key_a)

    provider_b = provider_fixture()
    key_b = credential_fixture(provider_b)
    lane_b = lane_fixture(model_, key_b)

    log(member, model_, %{lane_id: lane_a.id, credential_id: key_a.id, cost: "1.25"})
    log(member, model_, %{lane_id: lane_b.id, credential_id: key_b.id, cost: "2.75"})

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    assert real_text(view) =~ "$4.00"
    refute has_element?(view, "#credential-select")
  end

  # ---------------------------------------------------------------------------
  # (f) Lane que no cobra por tokens: aviso y sin estimado
  # ---------------------------------------------------------------------------

  test "a per_request lane warns and renders no estimate", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)
    member = group_member_fixture()

    lane =
      lane_fixture(model_, credential, %{
        pricing_unit: "per_request",
        unit_cost: "0.02",
        provider_model: "flat-lane-#{unique()}"
      })

    log(member, model_, %{lane_id: lane.id, credential_id: credential.id, cost: "4.00"})

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    assert has_element?(view, "#lane-unit-notice")
    refute has_element?(view, "#calc-estimated")
    # El real sí se muestra.
    assert has_element?(view, "#calc-real")
    assert real_text(view) =~ "$4.00"
  end

  # ---------------------------------------------------------------------------
  # (g) Cambiar de modelo limpia lane y key
  # ---------------------------------------------------------------------------

  test "changing the model clears lane and key and falls back to the whole model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    member = group_member_fixture()

    model_a = model_fixture()
    provider_a = provider_fixture()
    key_a = credential_fixture(provider_a, %{name: "model-a-key"})
    {lane_a, _pool} = pool_lane_fixture(model_a, provider_a, [key_a])

    model_b = model_fixture()
    provider_b = provider_fixture()
    key_b1 = credential_fixture(provider_b)
    key_b2 = credential_fixture(provider_b)
    lane_b1 = lane_fixture(model_b, key_b1)
    lane_b2 = lane_fixture(model_b, key_b2)

    log(member, model_a, %{lane_id: lane_a.id, credential_id: key_a.id, cost: "1.00"})
    log(member, model_b, %{lane_id: lane_b1.id, credential_id: key_b1.id, cost: "2.00"})
    log(member, model_b, %{lane_id: lane_b2.id, credential_id: key_b2.id, cost: "3.00"})

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_a.id})
    change(view, %{model_id: model_a.id, lane_id: lane_a.id})

    assert real_text(view) =~ "$1.00"
    assert has_element?(view, "#credential-select")

    # Cambiar de modelo: las lanes del anterior desaparecen y la key se suelta.
    change(view, %{model_id: model_b.id})

    refute has_element?(view, "#lane-select option[value='#{lane_a.id}']")
    refute has_element?(view, "#credential-select")
    assert has_element?(view, "#lane-select option[value='#{lane_b1.id}']")
    assert has_element?(view, "#lane-select option[value='#{lane_b2.id}']")
    # Sin lane, el real vuelve a ser TODO el modelo nuevo.
    assert real_text(view) =~ "$5.00"
  end

  # ---------------------------------------------------------------------------
  # (h) Periodo canónico en la URL (F1/P1)
  # ---------------------------------------------------------------------------

  test "the period selector offers the canonical set and lives in the URL", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()

    {:ok, view, html} = live(login(conn, admin, password), ~p"/calculator")

    # The canonical set, as patch links — no page-local literal list and no
    # <select> of its own.
    for period <- ~w(today yesterday week 30d) do
      assert has_element?(view, "#period-#{period}[href='/calculator?period=#{period}']")
    end

    refute has_element?(view, "#period-7d")
    refute has_element?(view, "#period-month")
    refute has_element?(view, "#period-last_month")
    refute html =~ "name=\"period\""

    # Defaults to the canonical default when the URL says nothing.
    assert has_element?(view, "#period-#{Tokengate.Periods.default_period()}.btn-primary")
    assert has_element?(view, "#calc-empty")
    _ = model_
  end

  test "an out-of-set bookmark degrades to the default instead of crashing", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    for bogus <- ~w(month last_month 7d banana) do
      {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=#{bogus}")

      assert has_element?(view, "#period-#{Tokengate.Periods.default_period()}.btn-primary")
      assert has_element?(view, "#calculator-form")
    end
  end

  test "patching the period repaints the real spend of the selected model", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)
    lane = lane_fixture(model_, credential, %{provider_model: "period-lane-#{unique()}"})

    # Inside 30d, outside the current week (10 days ago).
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_id: model_.id,
        model_provider_id: lane.id,
        credential_id: credential.id,
        model_requested: model_.name,
        model_responded: model_.name,
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 1_000,
        completion_tokens: 500,
        provider_cost_usd: Decimal.new("0.25"),
        latency_ms: 10,
        streaming: false,
        inserted_at:
          DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")
    change(view, %{model_id: model_.id})

    assert real_text(view) =~ "$0.25"

    # The patch link is navigation, not a form event: handle_params reloads.
    view |> element("#period-week") |> render_click()

    assert real_text(view) =~ "$0"
    refute real_text(view) =~ "$0.25"
  end

  # ---------------------------------------------------------------------------
  # (i) Dinero y precios: sub-centavo visible, sin defaults silenciosos (F16/P14)
  # ---------------------------------------------------------------------------

  test "a sub-cent real spend stays visible instead of reading as zero", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)
    lane = lane_fixture(model_, credential, %{provider_model: "tiny-lane-#{unique()}"})

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "0.000004",
      prompt_tokens: 10,
      completion_tokens: 5
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")
    change(view, %{model_id: model_.id})

    # The money cell carries the sub-cent amount — the point of money/1 is
    # exactly that it does not collapse to "$0.00".
    assert view |> element("#calc-real p.tabular-nums") |> render() =~ "$0.000004"
  end

  test "a lane without a price prefills an empty field and is flagged", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "no-cache-price-#{unique()}",
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "3.00",
        output_cost_per_million: "15.00"
      })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    # "no price" is NOT "free": the input stays empty (a "0.00" prefill read as
    # a free lane) and the form says which rate carries no price.
    assert has_element?(view, "#cost-cache[value='']")
    assert has_element?(view, "#calc-price-issues")
    assert view |> element("#calc-price-issues") |> render() =~ "cache"
  end

  test "a typed decimal comma is honored, not replaced by the default", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "comma-lane-#{unique()}",
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "0",
        cache_cost_per_million: "0",
        cache_write_cost_per_million: "0",
        output_cost_per_million: "0"
      })

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "0.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 0
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})

    html = change(view, %{model_id: model_.id, lane_id: lane.id, cost_input: "9,5"})

    # The typed value survives as typed and the estimate uses 9.5 — the old
    # parse dropped it and priced with the hardcoded 3.00.
    assert html =~ ~s(value="9,5")
    assert estimated_text(view) =~ "$9.5"
    refute has_element?(view, "#calc-price-issues")
  end

  test "an invalid price is flagged and never silently becomes the default", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "invalid-price-#{unique()}",
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "0",
        cache_cost_per_million: "0",
        cache_write_cost_per_million: "0",
        output_cost_per_million: "0"
      })

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "0.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 0
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})
    change(view, %{model_id: model_.id, lane_id: lane.id, cost_input: "abc"})

    assert has_element?(view, "#calc-price-issues")
    assert view |> element("#calc-price-issues") |> render() =~ "input"
    # Counted as $0, not as the old 3.00 default.
    assert estimated_text(view) =~ "$0.00"
  end

  test "NaN is rejected as a price instead of poisoning the estimate", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    credential = credential_fixture(provider)

    lane =
      lane_fixture(model_, credential, %{
        provider_model: "nan-price-#{unique()}",
        input_cost_per_million: "2.00",
        output_cost_per_million: "10.00"
      })

    log(member, model_, %{
      lane_id: lane.id,
      credential_id: credential.id,
      cost: "1.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane.id})
    change(view, %{model_id: model_.id, lane_id: lane.id, cost_input: "NaN"})

    assert has_element?(view, "#calc-price-issues")
    # $0 for the input term, not a NaN that would render "NaN" as money.
    refute estimated_text(view) =~ "NaN"
    assert estimated_text(view) =~ "$10"
  end

  test "the difference colors the sign right: overpaying is an error, underpaying success", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    member = group_member_fixture()
    provider = provider_fixture()
    key_a = credential_fixture(provider)
    key_b = credential_fixture(provider)

    prices = %{
      pricing_unit: "per_1m_tokens",
      input_cost_per_million: "2.00",
      cache_cost_per_million: "0",
      cache_write_cost_per_million: "0",
      output_cost_per_million: "10.00"
    }

    lane_a = lane_fixture(model_, key_a, Map.put(prices, :provider_model, "over-#{unique()}"))
    lane_b = lane_fixture(model_, key_b, Map.put(prices, :provider_model, "under-#{unique()}"))

    # 1M in + 1M out at those rates = $12.00 estimated on both lanes.
    log(member, model_, %{
      lane_id: lane_a.id,
      credential_id: key_a.id,
      cost: "20.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000
    })

    log(member, model_, %{
      lane_id: lane_b.id,
      credential_id: key_b.id,
      cost: "5.00",
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000
    })

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    # Real $20 > estimate $12: paying MORE must not read as success.
    change(view, %{model_id: model_.id})
    change(view, %{model_id: model_.id, lane_id: lane_a.id})

    difference = view |> element("#calc-difference") |> render()
    assert difference =~ "text-error"
    refute difference =~ "text-success"
    assert difference =~ "+$8.00"

    # Real $5 < estimate $12: the estimate was pessimistic.
    change(view, %{model_id: model_.id, lane_id: lane_b.id})

    difference = view |> element("#calc-difference") |> render()
    assert difference =~ "text-success"
    refute difference =~ "text-error"
    assert difference =~ "−$7.00"
  end

  test "a client id that is not a UUID renders the empty state instead of crashing", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, view, _html} = live(login(conn, admin, password), ~p"/calculator?period=30d")

    # A forged value cannot go through `form/3` (it validates select options):
    # this is exactly the malformed payload the cast must absorb.
    html =
      view
      |> element("#calculator-form")
      |> render_change(%{"model_id" => "not-a-uuid"})

    assert html =~ "Selecciona un modelo"
    assert has_element?(view, "#calc-empty")
  end
end
