defmodule Tokengate.SmartRouter.ShadowEvaluation do
  @moduledoc """
  One **Shadow** evaluation of a live request (`router_shadow_evaluations`).

  When a version is flagged `shadow_enabled`, a deterministic sample of the
  requests the Default already served is re-decided against that version's
  snapshot **after** the response was sent (`dry_run: true`: no session pin, no
  decision cache, no upstream call, no budget reservation). This table keeps
  the counterfactual: what the Default decided versus what the Shadow would
  have decided, both priced with the real token counts of the request.

  ## Why its own table (and no FK to `request_logs`)

  `request_logs` is partitioned by day and its rows are dropped with their
  partition, and it is the accounting record — shadow rows there would leak
  into `Budgets`, `/stats` and the hourly rollups. So the pair that identifies
  the parent is stored as plain values, `(request_log_id, request_inserted_at)`,
  and this table is pruned independently by
  `PartitionWorker.prune_shadow_evaluations/1` with the same retention window.

  `shadow_config_id` is the only foreign key (`ON DELETE DELETE ALL`): an
  evaluation of a deleted version is meaningless, while the log row it points
  at must outlive it. `shadow_config_name` is denormalised so the row stays
  readable after a rename.

  ## Agreement flags

  `matches_default_model` / `matches_default_tier` are written by the
  evaluator. They are booleans, not derived on read, so the discrepancy filters
  in `/catalog/router` and `/stats/router` are plain indexes over a window
  instead of a comparison of two nullable strings per row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.SmartRouter.Config

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "router_shadow_evaluations" do
    # The log this evaluation refers to. No FK: `request_logs` is partitioned
    # and pruned by dropping partitions.
    field :request_log_id, :binary_id
    field :request_inserted_at, :utc_datetime

    # The version that actually served the request (the Default at the time).
    field :default_config_id, :binary_id

    belongs_to :shadow_config, Config, foreign_key: :shadow_config_id

    field :shadow_config_name, :string

    # What the Default decided and what it actually cost.
    field :default_use_case_key, :string
    field :default_effort_tier, :string
    field :default_model_id, :binary_id
    field :default_model_name, :string
    field :default_served_cost_usd, :decimal

    # What the Shadow version would have decided.
    field :use_case_key, :string
    field :effort_tier, :string
    field :model_id, :binary_id
    field :model_name, :string
    field :decision_source, :string
    field :decision_ms, :integer
    # Classifier cost of the shadow decision itself (never billed to anybody).
    field :decision_cost_usd, :decimal
    field :prompt_tokens_saved_est, :integer
    field :estimated_served_cost_usd, :decimal

    field :matches_default_model, :boolean, default: false
    field :matches_default_tier, :boolean, default: false
    field :error_reason, :string

    field :inserted_at, :utc_datetime
  end

  @permitted ~w(request_log_id request_inserted_at default_config_id shadow_config_id
    shadow_config_name default_use_case_key default_effort_tier default_model_id
    default_model_name default_served_cost_usd use_case_key effort_tier model_id
    model_name decision_source decision_ms decision_cost_usd prompt_tokens_saved_est
    estimated_served_cost_usd matches_default_model matches_default_tier error_reason
    inserted_at)a

  @required ~w(request_log_id request_inserted_at shadow_config_id shadow_config_name)a

  @doc false
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, @permitted)
    |> put_inserted_at()
    |> validate_required(@required)
    |> validate_number(:decision_ms, greater_than_or_equal_to: 0)
    |> validate_number(:prompt_tokens_saved_est, greater_than_or_equal_to: 0)
    |> assoc_constraint(:shadow_config)
  end

  # `inserted_at` has no database default: the evaluator writes the row right
  # after the request completed, so "now" is the only correct value when the
  # caller does not pin one (tests pin it to exercise retention).
  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
