defmodule Tokengate.Metrics.SupervisorTest do
  @moduledoc """
  Smoke test for Tokengate.Metrics.Supervisor — verifies it starts the
  Collector child under one_for_one.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Metrics.Supervisor
  alias Tokengate.Metrics.Collector

  setup do
    pid = Process.whereis(Supervisor) || start_supervised!(Supervisor)
    _ = :sys.get_state(pid)
    :ok
  end

  test "supervisor starts Collector child" do
    assert is_pid(GenServer.whereis(Collector))
  end

  test "Collector is functional after supervisor start" do
    Collector.reset()

    Collector.record_request(%{
      model_alias_id: "alias-x",
      provider_id: "prov-y",
      agent_type: "api",
      status: 200,
      latency_ms: 42,
      prompt_tokens: 10,
      completion_tokens: 5,
      cost_usd: Decimal.new("0.100000"),
      savings_usd: Decimal.new("0.020000"),
      streaming: false
    })

    snap = Collector.snapshot()
    assert snap.requests_total == 1
    assert snap.by_alias == %{"alias-x" => 1}
    assert Decimal.equal?(snap.cost_usd, Decimal.new("0.100000"))
  end
end
