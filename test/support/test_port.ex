defmodule Tokengate.TestPort do
  @moduledoc """
  Ephemeral loopback ports for tests that bind a real HTTP listener.

  A fixed port (`@port 41234`) makes every test in a file reuse one address:
  when two listeners' lifetimes overlap — a `start_supervised!` whose shutdown
  has not landed yet, two Bandits in the same case, or simply a slow
  `:eaddrinuse`-free bind under load — the second bind fails. The OS assigns a
  free port instead, so each test owns its own listener and two suites can
  never collide on a hardcoded number.

  `listen(0)` asks the kernel for a free port and `close/1` releases it before
  Bandit binds; the window between the two calls is a few microseconds and no
  other test in this suite allocates ports concurrently (the suites that use
  this helper run `async: false`).
  """

  @doc "Returns a loopback port that is free at call time."
  @spec free_port() :: :inet.port_number()
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: :loopback])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
