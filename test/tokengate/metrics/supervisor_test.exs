defmodule Tokengate.Metrics.SupervisorTest do
  @moduledoc """
  Smoke test for Tokengate.Metrics.Supervisor — verifies it starts the
  Collector and RollupWorker children under one_for_one.
  """

  use ExUnit.Case, async: false
  alias Tokengate.Metrics.Collector
  alias Tokengate.Metrics.RollupWorker
  alias Tokengate.Metrics.Supervisor

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
      model_id: "model-x",
      provider_id: "prov-y",
      agent_type: "api",
      status: 200,
      latency_ms: 42,
      prompt_tokens: 10,
      completion_tokens: 5,
      cost_usd: Decimal.new("0.100000"),
      streaming: false
    })

    snap = Collector.snapshot()
    assert snap.requests_total == 1
    assert snap.by_model == %{"model-x" => 1}
    assert Decimal.equal?(snap.cost_usd, Decimal.new("0.100000"))
  end

  test "supervisor starts the RollupWorker, disabled in test by config" do
    assert is_pid(GenServer.whereis(RollupWorker))

    status = RollupWorker.status()

    # `config/test.exs` disables the background refresh: tests populate the
    # rollup explicitly, and a tick against the sandbox would fight the
    # per-test transaction. The worker still has to be SUPERVISED — the
    # self-healing tests start their own named instance.
    assert status.enabled? == false
    assert status.next_tick_in_ms == nil
    assert status.consecutive_failures == 0
  end
end
