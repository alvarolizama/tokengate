defmodule Tokengate.Repo.Migrations.AddCacheHitToRequestLogs do
  @moduledoc """
  Durable `cache_hit` flag on `request_logs`.

  A gateway-local response-cache hit booked a row at $0 / 0 tokens, and the
  only way to tell it apart from a genuinely cheap request was the response
  header the client received (`x-tokengate-cache: hit`) — the durable row had
  no marker. Aggregates and operator queries ("how much traffic is served
  without touching an upstream?") had to guess from `provider_cost_usd = 0`,
  which also matches unpriced models and error-free zero-cost responses.

  `cache_hit` is written `true` ONLY by the response-cache paths
  (`ProxyController.record_cache_hit/3`); every other path leaves the default.
  No backfill: the header was known at response time and the historical rows
  cannot be reconstructed reliably (a $0 row is ambiguous), so the default
  `false` is honest for the rows that existed before the column.

  `request_logs` is RANGE-partitioned on `inserted_at`: `ALTER TABLE` on the
  parent propagates the new column to every attached partition, and new daily
  partitions inherit it. The `NOT NULL` with a constant default is a
  metadata-only operation in Postgres (no table rewrite).
  """

  use Ecto.Migration

  def up do
    alter table(:request_logs) do
      add :cache_hit, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:request_logs) do
      remove :cache_hit
    end
  end
end
