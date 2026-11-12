defmodule Tokengate.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Tokengate.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Tokengate.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Tokengate.DataCase
    end
  end

  setup tags do
    Tokengate.DataCase.setup_sandbox(tags)

    # Allow the Oban supervisor (started in the app tree) to use the
    # sandboxed DB connection so assert_enqueued/drain_queue work in tests.
    # Oban performs DB inserts/queries in its own process; without this
    # allow, those queries can't see the test's sandbox transaction.
    case Process.whereis(Tokengate.Supervisor) do
      nil ->
        :ok

      sup ->
        case Enum.find(Supervisor.which_children(sup), fn {mod, _, _, _} -> mod == Oban end) do
          {Oban, oban_pid, _, _} ->
            Ecto.Adapters.SQL.Sandbox.allow(Tokengate.Repo, self(), oban_pid)

          _ ->
            :ok
        end
    end

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Also flushes the `DashboardCache` ETS table. That cache is global (a named
  public table owned by the app tree, not the sandbox) and several LiveViews
  (Users, Credits, Dashboard, UserStats) store whole-page bundles
  keyed by timezone/period. Its TTL outlives a single fast test, so without
  this flush a later test sharing a cache key could read the previous test's
  rows. Every affected LiveView test is `async: false`, so the flush is race-free.
  """
  def setup_sandbox(tags) do
    Tokengate.Metrics.DashboardCache.invalidate_all()
    # `Tokengate.Cache` is a VM-global ETS table (exemption sets, observability
    # destinations) whose TTL outlives the sandbox rollback: a later test
    # sharing a key would read the previous test's rows.
    Tokengate.Cache.invalidate_all()
    # `GlobalSettings` caches the daily cap in `:persistent_term` (hot path).
    # That term is VM-global and survives the sandbox rollback, so a test that
    # arms the kill-switch would leak the cap into the next test. Flush it with
    # the sandbox lifecycle, same as the dashboard cache above.
    Tokengate.GlobalSettings.reset_cache()
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Tokengate.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
