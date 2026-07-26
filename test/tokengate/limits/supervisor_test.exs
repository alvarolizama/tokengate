defmodule Tokengate.Limits.SupervisorTest do
  @moduledoc """
  Smoke test for Tokengate.Limits.Supervisor — verifies it starts the
  Manager child under one_for_one.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Limits.Supervisor
  alias Tokengate.Limits.Manager

  setup do
    pid = Process.whereis(Supervisor) || start_supervised!(Supervisor)
    _ = :sys.get_state(pid)
    :ok
  end

  test "supervisor starts Manager child" do
    # The Manager registers itself under the name __MODULE__.
    assert is_pid(GenServer.whereis(Manager))
  end

  test "Manager is functional after supervisor start" do
    key = "sup-test-#{System.unique_integer([:positive])}"
    assert :ok = Manager.check_rate(key, 10)
    assert :ok = Manager.acquire_concurrency(key, 5)
    assert Manager.current_concurrency(key) == 1
    assert :ok = Manager.release(key)
    assert Manager.current_concurrency(key) == 0
  end
end
