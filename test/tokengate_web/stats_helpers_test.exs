defmodule TokengateWeb.StatsHelpersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TokengateWeb.StatsHelpers, as: Stats

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
      assert podium =~ "amber"
      # El icono del hub es una clase heroicons (máscara con currentColor):
      # el color del puesto lo hereda del span.
      assert podium =~ "hero-trophy"

      second = render_component(&Stats.medal/1, %{rank: 2})
      assert second =~ "aria-label=\"Puesto 2\""
      assert second =~ "slate"
      assert second =~ "hero-trophy"

      third = render_component(&Stats.medal/1, %{rank: 3})
      assert third =~ "aria-label=\"Puesto 3\""
      assert third =~ "orange"
      assert third =~ "hero-trophy"

      rest = render_component(&Stats.medal/1, %{rank: 7})

      assert rest =~ "aria-label=\"Puesto 7\""
      assert rest =~ "7"
      refute rest =~ "hero-trophy"
    end
  end
end
