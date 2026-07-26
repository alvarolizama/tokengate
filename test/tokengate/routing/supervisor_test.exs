defmodule Tokengate.Routing.SupervisorTest do
  use ExUnit.Case, async: false

  alias Tokengate.Routing.StickyTracker
  alias Tokengate.Routing.Supervisor, as: RoutingSupervisor

  # The supervisor starts the singleton StickyTracker (named GenServer +
  # named ETS table). async: false avoids collisions.

  setup do
    pid = Process.whereis(RoutingSupervisor) || start_supervised!(RoutingSupervisor)
    {:ok, %{sup_pid: pid}}
  end

  test "starts and supervises StickyTracker" do
    # The StickyTracker GenServer should be alive and registered.
    sticky_pid = GenServer.whereis(StickyTracker)
    assert is_pid(sticky_pid)
    assert Process.alive?(sticky_pid)
  end

  test "StickyTracker is a child of the supervisor", %{sup_pid: sup_pid} do
    children = Supervisor.which_children(sup_pid)
    {_, sticky_pid, _, _} = Enum.find(children, fn {id, _, _, _} -> id == StickyTracker end)
    assert is_pid(sticky_pid)
    assert Process.alive?(sticky_pid)
  end

  test "StickyTracker ETS table is created" do
    assert :ets.whereis(:tokengate_sticky_routes) != :undefined
  end

  test "sticky routing works end-to-end through the supervisor" do
    StickyTracker.put("sup-key", "sup-alias", "sup-ap")
    _ = :sys.get_state(StickyTracker)

    assert StickyTracker.get("sup-key", "sup-alias") == "sup-ap"
  end
end
