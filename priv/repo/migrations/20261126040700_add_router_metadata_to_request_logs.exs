defmodule Tokengate.Repo.Migrations.AddRouterMetadataToRequestLogs do
  @moduledoc """
  Router telemetry on `request_logs`.

  The invariant that makes every existing read keep working untouched:
  `model_id` / `model_requested` semantics do not change — `model_requested`
  keeps the alias the client sent (`"router"`) and `model_id` keeps the model
  that actually served, so `/stats`, the rollups and `Budgets` stay correct. The
  columns below are the *extra* metadata that makes the router auditable.

  ## Columns

    * `routed_via_router` — the routing flag the partial index is built on.
    * `model_resolved` — the resolved logical model name (`model_requested`
      keeps the literal alias, `model_id` the id: the pair makes the bill
      auditable and the feature measurable).
    * `router_use_case_id` / `router_use_case_key` — which specialty decided.
      The key is denormalised so a row survives the use case being renamed.
    * `router_use_case_model_id` — the binding that won.
    * `router_effort_tier` — the tier that was served.
    * `router_decision_source` — `session_pin`, `rule`, `fast_path`,
      `single_candidate`, `classifier`, `fallback_timeout`, `fallback_error` or
      `default` (plain string here; the vocabulary is enforced by the writer).
    * `router_decision_ms` / `router_decision_cost_usd` — the decision step's
      own latency and cost, kept OUT of `provider_cost_usd`.
    * `router_baseline_model_id` / `router_baseline_cost_usd` — the
      counterfactual, frozen at request time with the baseline lane's rates
      (`NULL` when no price could be computed: a saving is never invented).
    * `router_direct_access` — `false` = the subject spent there only through
      the router, i.e. the model is outside their direct ACL.
    * `prompt_tokens_saved_est` — prompt tokens the prompt-saving knobs trimmed.

  ## Index

  `request_logs` is RANGE-partitioned by day (~14 indexes per partition) and
  every analytical read filters a time window first. A single **partial** index
  on the parent — `(inserted_at) WHERE routed_via_router = true` — is inherited
  by every existing and future partition with zero write amplification for
  non-routed traffic, and it is the only index this wave adds. No general btree
  on router columns, and no router dimensions in `request_metrics_hourly`.

  ## No foreign keys

  Every router id is a plain `uuid`. `request_logs` must not gain FKs: they made
  deletes `O(referenced log rows)` and timed out in production (the repo dropped
  the old `model_id`/`provider_id` FKs for exactly that reason), and the router
  metadata is historical evidence that has to outlive the use case row.

  ## `routed_via_router NOT NULL DEFAULT false`

  Metadata-only in Postgres 11+: existing rows read the default without a
  rewrite, and `false` is the honest value for every row written before the
  column existed.

  Reversible: `down/0` drops the index and then the columns.
  """

  use Ecto.Migration

  @router_index :request_logs_routed_via_router_inserted_at_idx

  def up do
    alter table(:request_logs) do
      add :routed_via_router, :boolean, null: false, default: false
      add :model_resolved, :string
      add :router_use_case_id, :binary_id
      add :router_use_case_key, :string
      add :router_use_case_model_id, :binary_id
      add :router_effort_tier, :string
      add :router_decision_source, :string
      add :router_decision_ms, :integer
      add :router_decision_cost_usd, :decimal, precision: 12, scale: 6
      add :router_baseline_model_id, :binary_id
      add :router_baseline_cost_usd, :decimal, precision: 12, scale: 6
      add :router_direct_access, :boolean
      add :prompt_tokens_saved_est, :integer
    end

    # On the partitioned parent: Postgres propagates it to every partition,
    # present and future (`PartitionWorker.attach_with_backfill/2` clones the
    # default partition INCLUDING ALL). CONCURRENTLY is not supported here.
    create index(:request_logs, [:inserted_at],
             where: "routed_via_router = true",
             name: @router_index
           )
  end

  def down do
    drop index(:request_logs, [:inserted_at], name: @router_index)

    alter table(:request_logs) do
      remove :prompt_tokens_saved_est
      remove :router_direct_access
      remove :router_baseline_cost_usd
      remove :router_baseline_model_id
      remove :router_decision_cost_usd
      remove :router_decision_ms
      remove :router_decision_source
      remove :router_effort_tier
      remove :router_use_case_model_id
      remove :router_use_case_key
      remove :router_use_case_id
      remove :model_resolved
      remove :routed_via_router
    end
  end
end
