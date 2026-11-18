# Per-partition ExUnit concurrency cap.
#
# With OS-process partitioning (scripts/test-parallel.sh) every partition is its
# own BEAM VM with its own Repo pool (TEST_POOL_SIZE connections). Async tests
# check out one connection each, so max_cases must stay below the pool size or
# tests will queue on DBConnection checkout (15s timeout → flaky failures).
# Unset = ExUnit default (schedulers * 2), which is right for a single run.
max_cases =
  case System.get_env("TEST_MAX_CASES") do
    nil ->
      nil

    "" ->
      nil

    value ->
      case Integer.parse(value) do
        {n, ""} when n > 0 ->
          n

        _ ->
          raise "TEST_MAX_CASES must be a positive integer, got: #{inspect(value)}"
      end
  end

opts = if max_cases, do: [max_cases: max_cases], else: []

case System.get_env("MIX_TEST_PARTITION") do
  nil ->
    :ok

  partition ->
    repo = Application.get_env(:tokengate, Tokengate.Repo, [])

    IO.puts(
      "[test-parallel] partition #{partition} pool=#{repo[:pool_size]} max_cases=#{max_cases}"
    )
end

ExUnit.start(opts)
Ecto.Adapters.SQL.Sandbox.mode(Tokengate.Repo, :manual)
