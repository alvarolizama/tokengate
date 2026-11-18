defmodule Tokengate.Logs.PartitionWorkerTest do
  @moduledoc """
  Tests for `Tokengate.Logs.PartitionWorker`: partition creation, idempotent
  ensure, backfill of rows stranded in the default partition, and
  retention cleanup.

  These tests mutate the shared `request_logs` partition structure, so they
  run `async: false`. Postgres DDL is transactional, so the sandbox rolls the
  partitions back after each test. Test partitions use far dates (2099 /
  2020) that cannot collide with real data.
  """

  use Tokengate.DataCase, async: false
  alias Tokengate.Logs.PartitionWorker
  alias Tokengate.Repo

  @future_a ~D[2099-03-01]
  @future_b ~D[2099-03-02]
  @old ~D[2020-06-15]

  # Insert a raw row directly into request_logs so we can control which
  # partition it lands in without building the full Accounts FK chain.
  defp raw_log_insert(inserted_at) do
    Repo.query!(
      """
      INSERT INTO request_logs (id, model_requested, inserted_at)
      VALUES ($1, 'test-model', $2)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), DateTime.new!(inserted_at, ~T[12:00:00])]
    )
  end

  defp partition_exists?(name) do
    Repo.query!("SELECT to_regclass($1)", ["public." <> name]).rows != [[nil]]
  end

  defp rows_in(table) do
    Repo.query!("SELECT count(*) FROM #{table}").rows |> List.flatten() |> hd()
  end

  defp rows_in_parent_between(%Date{} = from_day, %Date{} = to_day) do
    Repo.query!(
      "SELECT count(*) FROM request_logs WHERE inserted_at >= $1::timestamp AND inserted_at < $2::timestamp",
      [DateTime.new!(from_day, ~T[00:00:00]), DateTime.new!(to_day, ~T[00:00:00])]
    ).rows
    |> List.flatten()
    |> hd()
  end

  defp rows_in_default_between(%Date{} = from_day, %Date{} = to_day) do
    Repo.query!(
      """
      SELECT count(*) FROM request_logs_default
      WHERE inserted_at >= $1::timestamp AND inserted_at < $2::timestamp
      """,
      [DateTime.new!(from_day, ~T[00:00:00]), DateTime.new!(to_day, ~T[00:00:00])]
    ).rows
    |> List.flatten()
    |> hd()
  end

  defp bulk_log_insert(date, count) do
    Repo.query!(
      """
      INSERT INTO request_logs (id, model_requested, inserted_at)
      SELECT gen_random_uuid(), 'bulk-model', $1::timestamp + (g || ' seconds')::interval
      FROM generate_series(1, #{count}) AS g
      """,
      [DateTime.new!(date, ~T[00:00:00])]
    )
  end

  defp validated_check_constraint?(table, constraint) do
    Repo.query!(
      """
      SELECT convalidated FROM pg_constraint
      WHERE conrelid = to_regclass($1::text) AND conname = $2 AND contype = 'c'
      """,
      ["public." <> table, constraint]
    ).rows == [[true]]
  end

  describe "partition_name/1" do
    test "formats a date as request_logs_YYYY_MM_DD" do
      assert PartitionWorker.partition_name(~D[2099-03-01]) == "request_logs_2099_03_01"
      assert PartitionWorker.partition_name(~D[2026-12-31]) == "request_logs_2026_12_31"
    end
  end

  describe "ensure_upcoming_partitions/2" do
    test "creates partitions for base_date plus lookahead days" do
      {:ok, results} = PartitionWorker.ensure_upcoming_partitions(2, @future_a)

      assert {~D[2099-03-01], :created} = Enum.at(results, 0)
      assert {~D[2099-03-02], :created} = Enum.at(results, 1)
      assert {~D[2099-03-03], :created} = Enum.at(results, 2)

      assert partition_exists?(PartitionWorker.partition_name(@future_a))
      assert partition_exists?(PartitionWorker.partition_name(@future_b))
    end

    test "is idempotent — a second run reports :exists" do
      {:ok, _} = PartitionWorker.ensure_upcoming_partitions(0, @future_a)
      {:ok, results} = PartitionWorker.ensure_upcoming_partitions(0, @future_a)
      assert [{@future_a, :exists}] = results
    end
  end

  describe "backfill_default_partitions/1" do
    test "moves rows stranded in the default partition into their own partition" do
      # Land a row in the default partition (no partition exists for this date).
      raw_log_insert(@future_a)
      assert rows_in("request_logs_default") == 1

      {:ok, results} = PartitionWorker.backfill_default_partitions()

      assert {@future_a, :backfilled} = Enum.find(results, fn {d, _} -> d == @future_a end)

      # Row moved out of default, partition attached and holds the row.
      name = PartitionWorker.partition_name(@future_a)
      assert partition_exists?(name)
      assert rows_in("request_logs_default") == 0
      assert rows_in(name) == 1
    end

    test "is a no-op when the default partition is empty" do
      assert {:ok, []} = PartitionWorker.backfill_default_partitions()
    end

    test "skips days older than the retention cutoff" do
      # Insert a very old row into the default partition.
      raw_log_insert(@old)

      # With a 90-day retention, 2020 is far outside — left in the default.
      {:ok, results} = PartitionWorker.backfill_default_partitions(retention_days: 90)

      refute Enum.any?(results, fn {d, _} -> d == @old end)
      assert rows_in("request_logs_default") == 1
      refute partition_exists?(PartitionWorker.partition_name(@old))
    end
  end

  describe "prune_default_partition/1" do
    test "deletes ONLY expired days and leaves the default partition's recent rows alone" do
      expired_a = ~D[2020-03-01]
      expired_b = ~D[2020-03-02]
      recent = Date.utc_today()

      bulk_log_insert(expired_a, 1_200)
      bulk_log_insert(expired_b, 800)
      bulk_log_insert(recent, 300)

      assert rows_in_default_between(expired_a, Date.add(expired_b, 1)) == 2_000

      assert {:ok, %{days: 2, deleted: 2_000}} = PartitionWorker.prune_default_partition()

      # Expired days are gone from BOTH the default partition and the parent.
      assert rows_in_default_between(expired_a, Date.add(expired_b, 1)) == 0
      assert rows_in_parent_between(expired_a, Date.add(expired_b, 1)) == 0

      # The day inside retention is untouched.
      assert rows_in_parent_between(recent, Date.add(recent, 1)) == 300
    end

    test "measured: the delete is batched (bounded statements), not one giant DELETE" do
      # 55k rows in one expired day > the 50k batch, so the prune MUST split it
      # into more than one statement. This is the property the detach/recreate
      # alternative cannot offer: every statement is bounded, so the lock and
      # the dead-tuple burst stay bounded too.
      expired = ~D[2020-04-01]
      bulk_log_insert(expired, 55_000)

      test_pid = self()

      :telemetry.attach(
        "w10-prune-batches",
        [:tokengate, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          with %{query: query, result: {:ok, %{num_rows: rows}}} <- metadata,
               true <- String.starts_with?(query, "DELETE FROM request_logs_default") do
            send(pid, {:prune_statement, rows})
          end
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach("w10-prune-batches") end)

      {elapsed_us, {:ok, result}} =
        :timer.tc(fn -> PartitionWorker.prune_default_partition() end)

      assert %{days: 1, deleted: 55_000} = result

      batches = collect_batches([])

      assert length(batches) >= 2
      assert Enum.sum(batches) == 55_000
      assert Enum.max(batches) <= 50_000

      # Sanity bound on the measured cost (a single 55k-row DELETE in a
      # sandbox transaction is well under this on any dev box; the assertion is
      # here to catch a regression to per-row round trips).
      assert elapsed_us < 30_000_000
    end
  end

  defp collect_batches(acc) do
    receive do
      {:prune_statement, rows} -> collect_batches([rows | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "ATTACH hardening" do
    test "backfill validates the range CHECK before attaching (no scan under the lock)" do
      raw_log_insert(@future_a)

      {:ok, _} = PartitionWorker.backfill_default_partitions()

      name = PartitionWorker.partition_name(@future_a)

      # The constraint is what lets ATTACH PARTITION skip the validation scan
      # of the attached table, and it must be VALIDATED (an unvalidated CHECK
      # proves nothing to the planner/ATTACH).
      assert validated_check_constraint?(name, "#{name}_range_check")
    end
  end

  describe "cleanup_old_partitions/1" do
    test "drops partitions older than the cutoff, never the default" do
      # Create an old partition via ensure (handles empty default fine).
      {:ok, :created} = PartitionWorker.ensure_partition(@old)
      assert partition_exists?(PartitionWorker.partition_name(@old))

      # retention_days: 0 → cutoff is today, so the 2020 partition is dropped.
      {:ok, dropped} = PartitionWorker.cleanup_old_partitions(0)

      assert PartitionWorker.partition_name(@old) in dropped
      refute partition_exists?(PartitionWorker.partition_name(@old))

      # The default partition is never touched.
      names = PartitionWorker.list_partition_names()
      assert "request_logs_default" in names
    end

    test "keeps partitions within the retention window" do
      {:ok, :created} = PartitionWorker.ensure_partition(@future_a)

      # A large retention keeps the future partition.
      {:ok, dropped} = PartitionWorker.cleanup_old_partitions(90)
      refute PartitionWorker.partition_name(@future_a) in dropped
      assert partition_exists?(PartitionWorker.partition_name(@future_a))
    end
  end

  describe "perform/1" do
    test "runs ensure + backfill + cleanup end to end without error" do
      assert :ok = PartitionWorker.perform(%Oban.Job{})
    end
  end
end
