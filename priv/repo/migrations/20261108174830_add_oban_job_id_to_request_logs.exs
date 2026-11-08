defmodule Tokengate.Repo.Migrations.AddObanJobIdToRequestLogs do
  @moduledoc """
  Adds `oban_job_id` to `request_logs` — the idempotency key for Oban retries
  of `WriteWorker` jobs (C2).

  The unique index MUST include `inserted_at`: the table is RANGE-partitioned
  on `inserted_at` (`20260726000001_create_request_logs`), and a unique
  constraint on a partitioned table has to include the partition key. The
  pair `(oban_job_id, inserted_at)` is exactly the dedupe pair: Oban never
  executes the same job concurrently (attempts are sequential), and the
  enqueue sites pin `inserted_at` in the job args so every retry carries the
  SAME pair.

  DEPLOY NOTE: a unique-index build on the partitioned parent takes a lock
  across all partitions and Postgres does NOT support `CREATE INDEX
  CONCURRENTLY` on partitioned tables — production needs a maintenance
  window (or explicit acceptance of the lock time). Dev/test are unaffected.

  No data backfill: existing rows keep NULL and Postgres treats NULLs as
  distinct, so the index accepts them all.
  """

  use Ecto.Migration

  def up do
    alter table(:request_logs) do
      add :oban_job_id, :bigint
    end

    create unique_index(:request_logs, [:oban_job_id, :inserted_at])
  end

  def down do
    drop unique_index(:request_logs, [:oban_job_id, :inserted_at])

    alter table(:request_logs) do
      remove :oban_job_id
    end
  end
end
