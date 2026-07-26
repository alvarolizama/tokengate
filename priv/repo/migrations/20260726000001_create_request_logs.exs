defmodule Tokengate.Repo.Migrations.CreateRequestLogs do
  @moduledoc """
  Creates the request_logs table as a native Postgres RANGE-partitioned
  table on inserted_at (daily granularity).

  NOTE: An Oban cron creating daily partitions ahead of time is post-MVP;
  the default partition catches everything meanwhile.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE request_logs (
      id uuid NOT NULL,
      team_member_id uuid NOT NULL REFERENCES team_members(id),
      provider_id uuid REFERENCES providers(id),
      model_alias_id uuid REFERENCES model_aliases(id),
      subscription_id uuid REFERENCES provider_subscriptions(id),
      model_requested varchar(255) NOT NULL,
      model_responded varchar(255),
      agent_type varchar(255) NOT NULL DEFAULT 'unknown',
      status_code integer,
      prompt_tokens integer NOT NULL DEFAULT 0,
      completion_tokens integer NOT NULL DEFAULT 0,
      cost_usd numeric(12,6),
      provider_cost_usd numeric(12,6),
      savings_usd numeric(12,6),
      estimated_cost_usd numeric(12,6),
      latency_ms integer,
      streaming boolean NOT NULL DEFAULT false,
      inserted_at timestamp(0) NOT NULL,
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    execute "CREATE TABLE request_logs_default PARTITION OF request_logs DEFAULT"

    # Create a partition for 2026-07-26 so tests hit a real partition.
    # The default partition catches any dates without an explicit partition.
    execute "CREATE TABLE request_logs_2026_07_26 PARTITION OF request_logs FOR VALUES FROM ('2026-07-26') TO ('2026-07-27')"

    execute "CREATE INDEX request_logs_team_member_inserted_idx ON request_logs (team_member_id, inserted_at)"
    execute "CREATE INDEX request_logs_inserted_idx ON request_logs (inserted_at)"
  end

  def down do
    execute "DROP TABLE IF EXISTS request_logs CASCADE"
  end
end
