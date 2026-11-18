defmodule TokengateWeb.KpiHelpersTest do
  use Tokengate.DataCase, async: false
  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias TokengateWeb.KpiHelpers

  describe "assign_kpi_metrics/3 window" do
    # La ventana sale de Periods.period_bounds/2 y se aplican from Y to: una
    # ventana cerrada ("yesterday") que sólo pasara `from` sumaría también el
    # día en curso y el KPI no cuadraría con la ventana que la página declara.
    test "una ventana cerrada (yesterday) no suma el día en curso" do
      {:ok, user} =
        Accounts.register_user(%{
          email: "kpi-window-#{System.unique_integer([:positive])}@example.com",
          name: "KPI Window",
          password: "password-secret-1",
          global_role: "admin"
        })

      {:ok, group} = Accounts.create_group(%{name: "KPI #{System.unique_integer([:positive])}"})
      {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

      today = DateTime.utc_now() |> DateTime.truncate(:second)

      yesterday_mid =
        today
        |> DateTime.to_date()
        |> Date.add(-1)
        |> DateTime.new!(~T[12:00:00], "Etc/UTC")

      insert_log(member, yesterday_mid)
      insert_log(member, today)

      socket = %Phoenix.LiveView.Socket{}

      yesterday =
        KpiHelpers.assign_kpi_metrics(socket, user, period: "yesterday", timezone: "Etc/UTC")

      assert yesterday.assigns.kpi_metrics.requests_total == 1
      assert Decimal.equal?(yesterday.assigns.kpi_metrics.cost_usd, Decimal.new("0.010000"))

      today_metrics =
        KpiHelpers.assign_kpi_metrics(socket, user, period: "today", timezone: "Etc/UTC")

      assert today_metrics.assigns.kpi_metrics.requests_total == 1
    end
  end

  defp insert_log(member, at) do
    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "gpt-4o",
        status_code: 200,
        prompt_tokens: 10,
        completion_tokens: 5,
        provider_cost_usd: "0.010000",
        latency_ms: 20,
        streaming: false,
        inserted_at: at
      })

    :ok
  end

  describe "cache_hit_rate/2" do
    test "returns the percentage of input tokens served from cache" do
      # prompt_tokens INCLUDES cached tokens (OpenAI convention):
      # 40 read out of 200 total input = 20.0%
      assert KpiHelpers.cache_hit_rate(40, 200) == 20.0
    end

    test "100% when every input token came from cache" do
      assert KpiHelpers.cache_hit_rate(1_000, 1_000) == 100.0
    end

    test "0% when there are no cache reads" do
      assert KpiHelpers.cache_hit_rate(0, 500) == 0.0
    end

    test "rounds to one decimal" do
      # 1/3 = 33.333...% → 33.3
      assert KpiHelpers.cache_hit_rate(1, 3) == 33.3
    end

    test "returns nil when there is no input traffic at all" do
      assert KpiHelpers.cache_hit_rate(0, 0) == nil
    end

    test "returns nil for non-integer input" do
      assert KpiHelpers.cache_hit_rate(nil, 100) == nil
      assert KpiHelpers.cache_hit_rate(100, nil) == nil
    end
  end

  describe "format_hit_rate/1" do
    test "formats a float rate with the percent sign" do
      assert KpiHelpers.format_hit_rate(42.5) == "42.5%"
    end

    test "formats an integer rate with a trailing .0" do
      assert KpiHelpers.format_hit_rate(20) == "20.0%"
    end

    test "renders an em dash when the rate is nil" do
      assert KpiHelpers.format_hit_rate(nil) == "—"
    end
  end
end
