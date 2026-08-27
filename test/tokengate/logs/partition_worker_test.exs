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
