defmodule Tokengate.LogsCostSummaryRetentionTest do
  @moduledoc """
  Contrato de `Logs.cost_summary/1` frente a la retención de `request_logs`.

  El agregado corre sobre la tabla cruda, que se poda a
  `PartitionWorker.retention_days()` (90 por defecto). Una ventana sin `:from`
  —o que arranca antes del corte— solo puede devolver la parte que sobrevive,
  y antes eso salía como si fuera el total: `maybe_from/2` simplemente omitía
  el predicado de fecha y no había ni error ni aviso.

  Estos tests fijan el comportamiento nuevo: la ventana se recorta al corte y
  la truncación deja rastro en el log.
  """

  use Tokengate.DataCase, async: false

  import ExUnit.CaptureLog

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.PartitionWorker

  @base_attrs %{
    model_requested: "gpt-4",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    latency_ms: 500,
    streaming: false
  }

  defp member_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "Ret Group #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "ret-#{System.unique_integer([:positive])}@example.com",
        name: "Ret User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    member
  end

  defp log(member, inserted_at, cost) do
    attrs =
      @base_attrs
      |> Map.put(:group_member_id, member.id)
      |> Map.put(:provider_cost_usd, Decimal.new(cost))
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 24 * 3600, :second)

  # Un renglón fresco (dentro de la retención) y uno anterior al corte.
  defp seed_one_inside_one_outside(member) do
    log(member, days_ago(2), "0.010000")
    # Pasado el corte: sigue en la tabla (nadie purgó en este test), pero es
    # exactamente lo que el cron ya habría borrado.
    log(member, days_ago(PartitionWorker.retention_days() + 10), "9.990000")
  end

  describe "cost_summary/1 frente a la retención" do
    test "sin :from recorta al corte y avisa en el log" do
      member = member_fixture()
      seed_one_inside_one_outside(member)

      log_output =
        capture_log(fn ->
          summary = Logs.cost_summary(%{group_member_ids: [member.id]})

          # Solo cuenta lo que sobrevive a la retención, no el total histórico.
          assert Decimal.compare(summary.total_cost_usd, Decimal.new("0.010000")) == :eq
          assert summary.request_count == 1
        end)

      assert log_output =~ "TRUNCATED total"
      assert log_output =~ "no :from given"
    end

    test "un :from anterior al corte también se recorta y avisa" do
      member = member_fixture()
      seed_one_inside_one_outside(member)

      log_output =
        capture_log(fn ->
          summary =
            Logs.cost_summary(%{
              group_member_ids: [member.id],
              from: days_ago(PartitionWorker.retention_days() + 30)
            })

          assert Decimal.compare(summary.total_cost_usd, Decimal.new("0.010000")) == :eq
          assert summary.request_count == 1
        end)

      assert log_output =~ "TRUNCATED total"
      assert log_output =~ "older than the cutoff"
    end

    test "un :from dentro de la ventana no se toca ni avisa" do
      member = member_fixture()
      seed_one_inside_one_outside(member)

      log_output =
        capture_log(fn ->
          summary = Logs.cost_summary(%{group_member_ids: [member.id], from: days_ago(7)})

          # El renglón de hace 2 días entra; el de fuera del corte no.
          assert Decimal.compare(summary.total_cost_usd, Decimal.new("0.010000")) == :eq
          assert summary.request_count == 1
        end)

      refute log_output =~ "TRUNCATED total"
    end

    test "el :from recortado se refleja como frontera real, sin inventar datos" do
      member = member_fixture()
      seed_one_inside_one_outside(member)

      capture_log(fn ->
        clamped = Logs.cost_summary(%{group_member_ids: [member.id]})

        explicit_at_cutoff =
          Logs.cost_summary(%{
            group_member_ids: [member.id],
            from: PartitionWorker.cutoff_day()
          })

        # Recortar al corte == pedir explícitamente desde el corte.
        assert Decimal.compare(clamped.total_cost_usd, explicit_at_cutoff.total_cost_usd) == :eq
        assert clamped.request_count == explicit_at_cutoff.request_count
      end)
    end
  end

  describe "guards de retención" do
    test "el corte publicado por el worker es el que usa el clamp" do
      days = PartitionWorker.retention_days()

      assert Date.diff(Date.utc_today(), PartitionWorker.cutoff_day()) == days
      # El clamp usa el inicio de ese día UTC.
      assert %DateTime{hour: 0, minute: 0, second: 0} =
               DateTime.new!(PartitionWorker.cutoff_day(), ~T[00:00:00], "Etc/UTC")
    end

    test "la retención por defecto deja espacio a los deltas de 30d" do
      # El delta más ancho de la UI compara 30 días contra los 30 anteriores
      # (~60 días atrás). Por debajo de eso se truncaría en silencio.
      assert PartitionWorker.retention_days() >= 60
    end
  end

  describe "ensure_window!/2 en las fachadas de stats" do
    setup do
      original = Application.get_env(:tokengate, :strict_stats_windows)
      on_exit(fn -> Application.put_env(:tokengate, :strict_stats_windows, original) end)
      :ok
    end

    test "en modo estricto, una fachada sin :from levanta" do
      Application.put_env(:tokengate, :strict_stats_windows, true)
      member = member_fixture()

      # Las tres fachadas que aceptaban ventana opcional.
      assert_raise ArgumentError, ~r/called without :from/, fn ->
        Logs.user_stats(member.user_id)
      end

      assert_raise ArgumentError, ~r/called without :from/, fn ->
        Logs.service_stats(Ecto.UUID.generate())
      end

      assert_raise ArgumentError, ~r/called without :from/, fn ->
        Tokengate.Metrics.StatsQueries.summary([])
      end
    end

    test "en modo estricto, con :from dentro de la ventana pasa" do
      Application.put_env(:tokengate, :strict_stats_windows, true)
      member = member_fixture()
      log(member, days_ago(2), "0.010000")

      assert %{total_cost_usd: _} = Logs.user_stats(member.user_id, from: days_ago(7))
      assert %{request_count: _} = Tokengate.Metrics.StatsQueries.summary(from: days_ago(7))
    end

    test "fuera de modo estricto (producción) avisa y clampea en vez de tirar" do
      Application.put_env(:tokengate, :strict_stats_windows, false)
      member = member_fixture()
      seed_one_inside_one_outside(member)

      log_output =
        capture_log(fn ->
          # No levanta: devuelve el número parcial, con warning.
          summary = Logs.user_stats(member.user_id)
          assert summary.request_count == 1
        end)

      assert log_output =~ "TRUNCATED total"
    end
  end
end
