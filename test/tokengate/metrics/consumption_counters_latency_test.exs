defmodule Tokengate.Metrics.ConsumptionCountersLatencyTest do
  @moduledoc """
  Latencia y TTFT en los contadores durables.

  El detalle crudo (`request_logs`) se poda a los 90 días, así que las métricas
  de velocidad se perdían con las particiones. Los contadores ahora guardan
  `SUM` + `COUNT` de cada una (nunca un promedio: un promedio no es aditivo
  entre buckets) y `speed_by_subject/1` reconstruye el `AVG()` exacto para
  cualquier rango.

  Lo que estos tests fijan:
    * el trigger suma las cuatro columnas en el upsert por (sujeto, día);
    * `COUNT` cuenta los NO nulos, igual que el divisor de `AVG()` — un request
      fallido (sin latencia) o uno no-streaming (sin TTFT) no diluye;
    * la ruta de contadores cuadra con el agregado crudo al milisegundo.
  """

  use Tokengate.DataCase, async: false

  import Ecto.Query

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.ConsumptionCounter
  alias Tokengate.Metrics.ConsumptionCounters
  alias Tokengate.Repo

  @base_attrs %{
    model_requested: "gpt-4",
    status_code: 200,
    prompt_tokens: 10,
    completion_tokens: 5,
    streaming: true
  }

  defp user_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "Lat Group #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "lat-#{System.unique_integer([:positive])}@example.com",
        name: "Lat User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    {member, user}
  end

  defp log(member, inserted_at, overrides) do
    attrs =
      @base_attrs
      |> Map.merge(Map.new(overrides))
      |> Map.put(:group_member_id, member.id)
      |> Map.put(:provider_cost_usd, Decimal.new("0.010000"))
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  defp yesterday, do: DateTime.add(DateTime.utc_now(), -86_400, :second)

  describe "trigger: latencia y TTFT en el contador" do
    test "suma latencia y cuenta solo los no nulos" do
      {member, user} = user_fixture()
      at = yesterday()

      # 500 ms con TTFT de 100, 300 ms sin TTFT (no-streaming) y un fallido
      # sin latencia: dos muestras de latencia, una de TTFT.
      log(member, at, %{latency_ms: 500, ttft_ms: 100, streaming: true})
      log(member, at, %{latency_ms: 300, ttft_ms: nil, streaming: false})

      log(member, at, %{
        latency_ms: nil,
        ttft_ms: nil,
        streaming: false,
        status_code: 500
      })

      counter =
        Repo.one(
          from(c in ConsumptionCounter,
            where: c.user_id == ^user.id and c.day == ^DateTime.to_date(at)
          )
        )

      assert counter.request_count == 3
      assert counter.total_latency_ms == 800
      # `COUNT(latency_ms)` = 2: el fallido sin latencia no entra al divisor.
      assert counter.latency_count == 2
      assert counter.total_ttft_ms == 100
      assert counter.ttft_count == 1
    end

    test "speed_by_subject reconstruye el AVG exacto, e ignora los sin muestra" do
      {member, user} = user_fixture()
      at = yesterday()

      log(member, at, %{latency_ms: 500, ttft_ms: 100, streaming: true})
      log(member, at, %{latency_ms: 300, ttft_ms: nil, streaming: false})
      log(member, at, %{latency_ms: nil, ttft_ms: nil, status_code: 500})

      speeds = ConsumptionCounters.speed_by_subject(:user)
      entry = Map.fetch!(speeds, user.id)

      # (500 + 300) / 2, no /3: el divisor son las muestras reales.
      assert entry.avg_latency_ms == 400.0
      assert entry.latency_samples == 2
      assert entry.avg_ttft_ms == 100.0
      assert entry.ttft_samples == 1
    end

    test "cuadra con el agregado crudo de los logs, al milisegundo" do
      {member, user} = user_fixture()
      at = yesterday()

      log(member, at, %{latency_ms: 123, ttft_ms: 45, streaming: true})
      log(member, at, %{latency_ms: 877, ttft_ms: nil, streaming: false})
      log(member, at, %{latency_ms: nil, ttft_ms: nil, status_code: 502})

      raw =
        Repo.one(
          from(rl in RequestLog,
            where: rl.user_id == ^user.id,
            select: %{
              avg_latency: fragment("AVG(latency_ms)"),
              avg_ttft: fragment("AVG(ttft_ms)"),
              latency_n: count(rl.latency_ms),
              ttft_n: count(rl.ttft_ms)
            }
          )
        )

      entry = user.id |> then(&Map.fetch!(ConsumptionCounters.speed_by_subject(:user), &1))

      assert entry.avg_latency_ms == Float.round(Decimal.to_float(raw.avg_latency), 1)
      assert entry.avg_ttft_ms == Float.round(Decimal.to_float(raw.avg_ttft), 1)
      assert entry.latency_samples == raw.latency_n
      assert entry.ttft_samples == raw.ttft_n
    end

    test "un sujeto con bucket pero sin muestras reporta nil, no cero" do
      {member, user} = user_fixture()

      # Hay bucket (el log existe) pero cero muestras de latencia: el promedio
      # es nil, igual que `AVG()` sobre puros NULL — no un 0 que parezca medido.
      log(member, yesterday(), %{latency_ms: nil, ttft_ms: nil, status_code: 500})

      entry = Map.fetch!(ConsumptionCounters.speed_by_subject(:user), user.id)
      assert entry.avg_latency_ms == nil
      assert entry.avg_ttft_ms == nil
      assert entry.latency_samples == 0
      assert entry.ttft_samples == 0
    end
  end
end
