defmodule Tokengate.Metrics.TopupConsumptionCounter do
  @moduledoc """
  How much of one top-up has been consumed, as a durable counter.

  This is the authority `Tokengate.Credits.Topups.consumed_usd/1` reads. It used
  to sum the raw logs attributed to the top-up, and `request_logs` is pruned at
  90 days: a non-expiring top-up older than the retention lost its debits and
  its remaining credit grew back, resurrecting money that had already been
  spent (and the `Budgets.Manager` re-seed consolidated the inflated value).

  Kept exact by the same `request_logs` trigger as
  `Tokengate.Metrics.ConsumptionCounter`: `consumed_micro` is integer micro-USD
  (`ROUND(provider_cost_usd * 1_000_000)`), so it reconciles exactly with the
  logs. Cascades from `credit_topups`: deleting a top-up deletes its counter,
  while the historical attribution stays in `request_logs`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:topup_id, :binary_id, autogenerate: false}

  schema "topup_consumption_counters" do
    field :consumed_micro, :integer, default: 0
    field :request_count, :integer, default: 0
    timestamps(type: :utc_datetime, updated_at: :updated_at)
  end

  @doc false
  def changeset(counter, attrs) do
    counter
    |> cast(attrs, [:topup_id, :consumed_micro, :request_count])
    |> validate_required([:topup_id])
    |> foreign_key_constraint(:topup_id)
  end
end
