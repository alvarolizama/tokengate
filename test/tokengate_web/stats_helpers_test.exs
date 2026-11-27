defmodule TokengateWeb.StatsHelpersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TokengateWeb.StatsHelpers, as: Stats

  describe "canonical_periods/0" do
    test "el set canónico es exactamente today/yesterday/week/30d" do
      assert Stats.canonical_periods() == ~w(today yesterday week 30d)

      for period <- ~w(today yesterday week 30d) do
        assert Stats.canonical_period?(period)
      end

      refute Stats.canonical_period?("month")
      refute Stats.canonical_period?("last_month")
      refute Stats.canonical_period?("7d")
    end

    test "cada periodo canónico tiene label en español" do
      Gettext.put_locale(TokengateWeb.Gettext, "es")
      on_exit(fn -> Gettext.put_locale(TokengateWeb.Gettext, "en") end)

      assert Stats.period_label("today") == "Hoy"
      assert Stats.period_label("yesterday") == "Ayer"
      assert Stats.period_label("week") == "Esta semana"
      assert Stats.period_label("30d") == "30 días"

      for period <- Stats.canonical_periods() do
        assert Stats.period_label(period) != ""
      end
    end
  end

  describe "money/1" do
    test "cero exacto es $0.00" do
      assert Stats.money(Decimal.new(0)) == "$0.00"
      assert Stats.money(nil) == "$0.00"
    end

    test "sub-centavo mantiene 6 decimales, no colapsa a $0" do
      assert Stats.money(Decimal.new("0.000004")) == "$0.000004"
      assert Stats.money(Decimal.new("0.00021")) == "$0.00021"
      assert Stats.money(Decimal.new("0.009999")) == "$0.009999"
    end

    test "centavo en adelante usa 4 decimales" do
      assert Stats.money(Decimal.new("0.01")) == "$0.0100"
      assert Stats.money(Decimal.new("4.200000")) == "$4.2000"
    end

    test "por debajo de la resolución de la columna no colapsa a $0" do
      # Un costo real nunca se lee como «no se registró gasto».
      assert Stats.money(Decimal.new("0.0000004")) == "$0.0000004"
    end
  end

  # El 0 no es una ausencia: con tráfico de entrada y ningún acierto de caché
  # la tarjeta tiene que decir 0.0%, no «—» (que se lee como «no hay dato»).
  describe "cache_hit_pct/2" do
    test "cero aciertos con tráfico de entrada es 0.0%, no —" do
      assert Stats.cache_hit_pct(500, 0) == "0.0%"
    end

    test "calcula el porcentaje con un decimal" do
      assert Stats.cache_hit_pct(200, 40) == "20.0%"
      assert Stats.cache_hit_pct(1_000, 1_000) == "100.0%"
      assert Stats.cache_hit_pct(3, 1) == "33.3%"
    end

    test "sin denominador válido rinde —" do
      assert Stats.cache_hit_pct(0, 0) == "—"
      assert Stats.cache_hit_pct(0, 120) == "—"
      assert Stats.cache_hit_pct(nil, 10) == "—"
      assert Stats.cache_hit_pct(100, nil) == "—"
      assert Stats.cache_hit_pct(100, -1) == "—"
    end
  end

  describe "out_in_ratio/2" do
    test "salida sobre entrada en múltiplos compactos" do
      assert Stats.out_in_ratio(100, 200) == "0.5x"
      assert Stats.out_in_ratio(300, 100) == "3.0x"
    end

    test "sin entrada válida rinde —" do
      assert Stats.out_in_ratio(10, 0) == "—"
      assert Stats.out_in_ratio(10, nil) == "—"
      assert Stats.out_in_ratio(nil, 100) == "—"
    end
  end

  describe "cost_per_request/2" do
    test "costo medio por request con la precisión de money/1" do
      assert Stats.cost_per_request(Decimal.new("0.01"), 4) == "$0.0025"
      assert Stats.cost_per_request(Decimal.new("0.0004"), 100) == "$0.000004"
      assert Stats.cost_per_request(Decimal.new(0), 5) == "$0.00"
    end

    test "sin requests o sin costo Decimal rinde —" do
      assert Stats.cost_per_request(Decimal.new("0.01"), 0) == "—"
      assert Stats.cost_per_request(Decimal.new("0.01"), nil) == "—"
      assert Stats.cost_per_request(nil, 10) == "—"
      assert Stats.cost_per_request(0.01, 10) == "—"
    end
  end

  describe "effective_cost_per_1m/3" do
    test "costo observado por millón de tokens (entrada + salida)" do
      assert Stats.effective_cost_per_1m(Decimal.new("0.01"), 1_000, 1_000) == "$5.0000"
      assert Stats.effective_cost_per_1m(Decimal.new("0.000004"), 2_000_000, 0) == "$0.000002"
    end

    test "sin tokens o sin costo Decimal rinde —" do
      assert Stats.effective_cost_per_1m(Decimal.new("0.01"), 0, 0) == "—"
      assert Stats.effective_cost_per_1m(nil, 100, 100) == "—"
      assert Stats.effective_cost_per_1m(Decimal.new("0.01"), nil, 100) == "—"
    end
  end

  # El formato del hub (KPI cards incluidas) tiene una sola implementación:
  # KpiHelpers delega en StatsHelpers, así que el sub-centavo se lee igual en
  # las dos superficies.
  describe "KpiHelpers delega el formato en StatsHelpers" do
    test "kpi_cards/1 conserva el sub-centavo en el card de costo" do
      metrics = %{
        requests_total: 0,
        cost_usd: Decimal.new("0.00004"),
        prompt_tokens: 0,
        completion_tokens: 0,
        cache_read_tokens: 0,
        cache_creation_tokens: 0,
        avg_tps: nil
      }

      html = render_component(&TokengateWeb.KpiHelpers.kpi_cards/1, %{metrics: metrics})

      assert html =~ "$0.00004"
      refute html =~ "$0.00<"
    end

    test "los formateadores de KpiHelpers son los de StatsHelpers" do
      assert TokengateWeb.KpiHelpers.format_decimal(Decimal.new("0.01")) ==
               Stats.format_decimal(Decimal.new("0.01"))

      assert TokengateWeb.KpiHelpers.format_number(12_345) == Stats.format_number(12_345)
      assert TokengateWeb.KpiHelpers.format_compact(2_000_000) == Stats.format_compact(2_000_000)
      assert TokengateWeb.KpiHelpers.format_tps(12.34) == Stats.format_tps(12.34)
    end
  end

  defmodule CellWithBlock do
    @moduledoc "Envoltorio: metric_cell recibiendo el valor como BLOQUE, no como attr."
    use Phoenix.Component

    def cell(assigns) do
      ~H"""
      <Stats.metric_cell label="Tier" value="ignorado">
        <span class="badge">alto</span>
      </Stats.metric_cell>
      """
    end
  end

  describe "countdown_parts/2" do
    test "separa horas y minutos, minutos a dos dígitos" do
      now = ~U[2026-09-15 02:00:00Z]
      assert Stats.countdown_parts(~U[2026-09-15 03:05:00Z], now) == {"1", "05"}
      assert Stats.countdown_parts(~U[2026-09-16 00:00:00Z], now) == {"22", "00"}
    end

    test "redondea hacia arriba a minutos completos" do
      now = ~U[2026-09-15 02:24:49Z]
      assert Stats.countdown_parts(~U[2026-09-15 04:49:00Z], now) == {"2", "25"}
    end

    test "con menos de un minuto restante los minutos son 01, no 00" do
      assert Stats.countdown_parts(~U[2026-09-16 00:00:00Z], ~U[2026-09-15 23:59:30Z]) ==
               {"0", "01"}
    end

    test "instantes pasados o nil rinden {\"0\", \"00\"}" do
      now = ~U[2026-09-15 02:00:00Z]

      assert Stats.countdown_parts(now, now) == {"0", "00"}
      assert Stats.countdown_parts(DateTime.add(now, -100, :second), now) == {"0", "00"}
      assert Stats.countdown_parts(nil, now) == {"0", "00"}
    end
  end

  describe "format_countdown/2" do
    test "une las partes como H:MM" do
      now = ~U[2026-09-15 02:00:00Z]
      assert Stats.format_countdown(~U[2026-09-15 03:05:00Z], now) == "1:05"
      assert Stats.format_countdown(nil, now) == "0:00"
    end

    test "un día completo se lee 24:00" do
      assert Stats.format_countdown(~U[2026-09-16 00:00:00Z], ~U[2026-09-15 00:00:00Z]) ==
               "24:00"
    end

    test "usa la hora actual cuando no se pasa `now`" do
      target = DateTime.add(DateTime.utc_now(), 60, :second)
      assert Stats.format_countdown(target) in ["0:01", "1:00", "1:01"]
    end
  end

  describe "format_time/2" do
    test "rinde HH:MM en la zona pedida" do
      dt = ~U[2026-09-16 00:00:00Z]

      assert Stats.format_time(dt, "Etc/UTC") == "00:00"
      assert Stats.format_time(dt, "America/Merida") == "18:00"
      assert Stats.format_time(dt, "Europe/Madrid") == "02:00"
    end

    test "cae a UTC sin zona o con zona inválida" do
      dt = ~U[2026-09-16 00:00:00Z]

      assert Stats.format_time(dt) == "00:00"
      assert Stats.format_time(dt, "No/Existe") == "00:00"
      assert Stats.format_time(nil, "Etc/UTC") == "—"
    end
  end

  # El Resumen deriva su reparto ("Por proveedor" / "Por modelo") del agregado
  # modelo × proveedor que ya cargó: estas funciones son ese reparto, así que
  # se prueban con la forma cruda del agregado (sin DB).
  describe "reparto del período (model_rows/1, provider_legend/1, share_pct/2)" do
    defp dec(s), do: Decimal.new(s)

    defp stacked do
      [
        %{
          model_name: "gpt-4o",
          total_requests: 3,
          providers: [
            %{provider_name: "Anthropic", requests: 1, cost_usd: dec("0.020000")},
            %{provider_name: "OpenAI", requests: 2, cost_usd: dec("0.010000")}
          ]
        },
        %{
          model_name: "claude-3",
          total_requests: 2,
          providers: [%{provider_name: "Anthropic", requests: 2, cost_usd: dec("0.060000")}]
        }
      ]
    end

    test "model_rows/1 suma el costo de todos los proveedores del modelo" do
      assert [
               %{
                 model_name: "gpt-4o",
                 requests: 3,
                 provider_count: 2,
                 cost_usd: gpt_cost
               },
               %{model_name: "claude-3", requests: 2, provider_count: 1, cost_usd: claude_cost}
             ] = Stats.model_rows(stacked())

      assert Decimal.equal?(gpt_cost, dec("0.030000"))
      assert Decimal.equal?(claude_cost, dec("0.060000"))
    end

    test "provider_legend/1 agrega por proveedor cruzando modelos" do
      assert [
               %{provider_name: "Anthropic", requests: 3, cost_usd: anthropic},
               %{provider_name: "OpenAI", requests: 2, cost_usd: openai}
             ] = Stats.provider_legend(stacked())

      assert Decimal.equal?(anthropic, dec("0.080000"))
      assert Decimal.equal?(openai, dec("0.010000"))
    end

    test "model_provider_total/1 es la base del reparto y cubre los dos listados" do
      rows = stacked()

      assert Stats.model_provider_total(rows) == 5
      assert Enum.sum(Enum.map(Stats.model_rows(rows), & &1.requests)) == 5
      assert Enum.sum(Enum.map(Stats.provider_legend(rows), & &1.requests)) == 5
    end

    test "share_pct/2 sobre el total del período, con 0 cuando no hay total" do
      assert Stats.share_pct(3, 5) == 60.0
      assert Stats.share_pct(2, 5) == 40.0
      assert Stats.share_pct(0, 0) == 0.0
      assert Stats.share_pct(5, nil) == 0.0
    end
  end

  # Regresión: un componente con `slot :inner_block` recibe `[]` cuando se
  # llama sin bloque (lista vacía, truthy en Elixir), así que un
  # `if @inner_block` mandaba TODO valor escalar a un slot vacío y las celdas
  # de los listados rankeados del hub se pintaban en blanco.
  describe "metric_cell/1" do
    test "pinta el valor escalar cuando se llama sin bloque" do
      html = render_component(&Stats.metric_cell/1, %{label: "Requests", value: "42"})

      assert html =~ "42"
      assert html =~ "Requests"
    end

    test "el bloque manda sobre el valor cuando sí hay bloque" do
      html = render_component(&CellWithBlock.cell/1, %{})

      assert html =~ "alto"
      refute html =~ "ignorado"
    end
  end

  describe "medal/1" do
    test "medalla para el podio y número para el resto" do
      podium = render_component(&Stats.medal/1, %{rank: 1})

      assert podium =~ "aria-label=\"Puesto 1\""
      assert podium =~ "warning"
      # El icono del hub es una clase heroicons (máscara con currentColor):
      # el color del puesto lo hereda del span.
      assert podium =~ "hero-trophy"

      second = render_component(&Stats.medal/1, %{rank: 2})
      assert second =~ "aria-label=\"Puesto 2\""
      assert second =~ "base-300"
      assert second =~ "hero-trophy"

      third = render_component(&Stats.medal/1, %{rank: 3})
      assert third =~ "aria-label=\"Puesto 3\""
      assert third =~ "secondary"
      assert third =~ "hero-trophy"

      rest = render_component(&Stats.medal/1, %{rank: 7})

      assert rest =~ "aria-label=\"Puesto 7\""
      assert rest =~ "7"
      refute rest =~ "hero-trophy"
    end
  end

  # El chip de logo lo comparten todos los listados de stats (Resumen, Por
  # proveedor, detalle de modelo, hub en vivo). El icono genérico tiene que ir
  # SIEMPRE en el markup, oculto sólo cuando hay logo: una URL que responde 404
  # no dispara ningún fallback del servidor, así que el render viejo
  # (`img si logo_url / icono si nil`) dejaba el chip VACÍO y se leía como «a
  # este proveedor le falta el logo». Lo destapa el listener global de `error`
  # de app.js, que busca el `<img data-logo>` roto y libera el
  # `.hero-server-stack` que tiene al lado.
  describe "provider_logo/1" do
    # Ojo: el chip lleva `overflow-hidden`, así que `=~ "hidden"` a secas NO
    # prueba nada — hay que mirar la clase del icono, que empieza por
    # `hero-server-stack`.
    test "con logo pinta el img marcado y deja el icono oculto de reserva" do
      html =
        render_component(&Stats.provider_logo/1, %{logo_url: "https://x.test/logo.svg"})

      assert html =~ "data-logo"
      assert html =~ ~r/class="hero-server-stack[^"]*\bhidden\b/
    end

    test "sin logo pinta el icono visible y ningún img" do
      html = render_component(&Stats.provider_logo/1, %{logo_url: nil})

      refute html =~ "data-logo"
      assert html =~ ~r/class="hero-server-stack[^"]*"/
      refute html =~ ~r/class="hero-server-stack[^"]*\bhidden\b/
    end
  end
end
