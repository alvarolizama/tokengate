defmodule Tokengate.Repo.Migrations.MoveProviderLimitsToProviders do
  use Ecto.Migration

  # Operational limits (RPM, concurrency, per-user concurrency, receive
  # timeout) move from the API key to the provider: a credential is only an
  # alias + secret, and every key of a provider inherits the same throttle.
  #
  # `nil` keeps meaning "no limit" on all four (the receive timeout falls back
  # to the global config default), so a provider with no values behaves exactly
  # as before.
  def up do
    alter table(:providers) do
      add :max_rpm, :integer
      add :max_concurrent, :integer
      add :max_concurrent_per_user, :integer
      add :receive_timeout_ms, :integer
    end

    # Backfill from the credentials the provider already had: the most
    # restrictive (MIN) non-null value among its keys, so no key ends up with
    # MORE headroom than before the move. A provider whose keys carried no
    # limits stays NULL = unlimited.
    execute("""
    UPDATE providers p
    SET max_rpm = agg.max_rpm,
        max_concurrent = agg.max_concurrent,
        max_concurrent_per_user = agg.max_concurrent_per_user,
        receive_timeout_ms = agg.receive_timeout_ms
    FROM (
      SELECT provider_id,
             min(max_rpm) AS max_rpm,
             min(max_concurrent) AS max_concurrent,
             min(max_concurrent_per_user) AS max_concurrent_per_user,
             min(receive_timeout_ms) AS receive_timeout_ms
      FROM provider_credentials
      GROUP BY provider_id
    ) agg
    WHERE agg.provider_id = p.id
    """)

    alter table(:provider_credentials) do
      remove :max_rpm
      remove :max_concurrent
      remove :max_concurrent_per_user
      remove :receive_timeout_ms
    end
  end

  def down do
    alter table(:provider_credentials) do
      add :max_rpm, :integer
      add :max_concurrent, :integer
      add :max_concurrent_per_user, :integer
      add :receive_timeout_ms, :integer
    end

    # The provider value is the only source left, so it is copied onto each of
    # its keys: the effective limits stay identical to what `up` produced
    # (only the original per-key divergence is not recoverable).
    execute("""
    UPDATE provider_credentials c
    SET max_rpm = p.max_rpm,
        max_concurrent = p.max_concurrent,
        max_concurrent_per_user = p.max_concurrent_per_user,
        receive_timeout_ms = p.receive_timeout_ms
    FROM providers p
    WHERE c.provider_id = p.id
    """)

    alter table(:providers) do
      remove :max_rpm
      remove :max_concurrent
      remove :max_concurrent_per_user
      remove :receive_timeout_ms
    end
  end
end
