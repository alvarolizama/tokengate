defmodule Tokengate.Metrics.RequestMetricsHourly do
  @moduledoc """
  Hourly rollup of `request_logs` — one row per (day, hour_utc,
  group_member_id, model_id, provider_id) dimension bucket.

  Fully derived and rebuildable; `request_logs` remains the source of
  truth. Written by `Tokengate.Metrics.Rollup.aggregate_hours/2` via
  idempotent upserts and kept fresh for recent hours by
  `Tokengate.Metrics.RollupWorker`.

  `cost_micro` stores cost as integer micro-USD (`round(usd * 1_000_000)`)
  so `SUM` is exact integer arithmetic — no Decimal aggregation cost.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "request_metrics_hourly" do
    field :day, :date

    field :hour_utc, :utc_datetime
    # Identidad durable del gasto (misma que request_logs.user_id): las
    # lecturas por usuario se sirven del rollup sin depender de que la
    # membresía (group_member_id) siga viva. NULL en los buckets de servicio.
    field :user_id, :binary_id
    field :group_member_id, :binary_id
    field :model_id, :binary_id
    field :provider_id, :binary_id

    field :request_count, :integer
    field :error_count, :integer
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cache_read_tokens, :integer
    field :cache_creation_tokens, :integer
    field :cost_micro, :integer
    field :total_latency_ms, :integer
    field :latency_count, :integer

    field :inserted_at, :utc_datetime
    field :updated_at, :utc_datetime
  end

  @fields ~w(day hour_utc user_id group_member_id model_id provider_id request_count error_count
    prompt_tokens completion_tokens cache_read_tokens cache_creation_tokens cost_micro
    total_latency_ms latency_count)a

  @doc """
  Changeset for the idempotent upsert in `Rollup.aggregate_hours/2`.

  Dimension fields (day, hour_utc, and the three nullable ids) come from
  the GROUP BY of the aggregation query; measures are additive counters.
  """
  def changeset(rollup, attrs) do
    import Ecto.Changeset

    rollup
    |> cast(attrs, @fields ++ [:inserted_at, :updated_at])
    |> validate_required([:day, :hour_utc, :request_count])
    |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
