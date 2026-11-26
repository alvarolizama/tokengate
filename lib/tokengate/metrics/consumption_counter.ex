defmodule Tokengate.Metrics.ConsumptionCounter do
  @moduledoc """
  Durable per-subject, per-day consumption counter (UTC day).

  One row per `(user_id, day)` or `(service_id, day)` — a nullable XOR, exactly
  one subject per row. Derived from `request_logs` and kept exact by the
  trigger created in `20261122064158_create_consumption_counters`, so the
  numbers cannot drift from the logs: the trigger fires in the same transaction
  as each log insert, and a deduplicated retry (`ON CONFLICT DO NOTHING`)
  inserts no row and bumps nothing.

  Amounts are integer **micro-USD**, the same unit as the hourly rollup:
  `provider_cost_usd` is `numeric(12,6)`, so `ROUND(usd * 1_000_000)` is lossless
  and sums reconcile exactly against `SUM(provider_cost_usd)`.

  `spend_micro` counts every request; `limit_spend_micro` counts only the rows
  debited to the subject's own limit (no `credit_topup_id`), which is the amount
  that consumes the monthly cap. They are separate columns because the credit
  engine needs both.

  Unlike the hourly rollup, this table is **not** pruned by the log retention:
  it is the durable record that survives the raw partitions (that is what makes
  lifetime totals and long-lived top-ups correct).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "consumption_counters" do
    field :user_id, :binary_id
    field :service_id, :binary_id
    field :day, :date
    field :request_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :spend_micro, :integer, default: 0
    field :limit_spend_micro, :integer, default: 0
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0
    # Sum + count, never an average: an average is not additive across buckets.
    # `*_count` is a separate divisor because AVG() skips NULLs — a failed
    # request (no latency) or a non-streaming one (no TTFT) must not dilute.
    field :total_latency_ms, :integer, default: 0
    field :latency_count, :integer, default: 0
    field :total_ttft_ms, :integer, default: 0
    field :ttft_count, :integer, default: 0
    timestamps(type: :utc_datetime, updated_at: :updated_at)
  end

  @fields ~w(day request_count error_count spend_micro limit_spend_micro prompt_tokens
    completion_tokens cache_read_tokens cache_creation_tokens total_latency_ms
    latency_count total_ttft_ms ttft_count)a

  @doc false
  def changeset(counter, attrs) do
    counter
    |> cast(attrs, [:user_id, :service_id] ++ @fields)
    |> validate_required([:day])
    |> check_subject_xor()
    |> unique_constraint(:day, name: :consumption_counters_user_day_idx)
    |> unique_constraint(:day, name: :consumption_counters_service_day_idx)
    |> foreign_key_constraint(:service_id)
    |> check_constraint(:user_id, name: :consumption_counters_subject_xor)
  end

  defp check_subject_xor(changeset) do
    user_id = get_field(changeset, :user_id)
    service_id = get_field(changeset, :service_id)

    if is_nil(user_id) == is_nil(service_id) do
      add_error(changeset, :user_id, "exactly one subject (user or service) is required")
    else
      changeset
    end
  end
end
