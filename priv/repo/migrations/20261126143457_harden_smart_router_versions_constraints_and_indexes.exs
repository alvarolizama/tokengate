defmodule Tokengate.Repo.Migrations.HardenSmartRouterVersionsConstraintsAndIndexes do
  @moduledoc """
  Hardens `router_configs` and aligns `router_shadow_evaluations` indexes with
  the actual `Analytics.shadow_*` `request_inserted_at` window filters:

    * `router_configs_default_not_archived_check` prevents a concurrent race
      between `archive_version!/1` and `promote_to_default!/2` from leaving the
      serving Default archived.
    * Replaces `(:shadow_config_id, :inserted_at)` with
      `(:shadow_config_id, :request_inserted_at)` and adds
      `(:request_inserted_at)` so `shadow_comparison/1` and
      `shadow_migrations/2` hit index range scans instead of sequential scans,
      while keeping `(:inserted_at)` for `PartitionWorker` retention pruning.
  """

  use Ecto.Migration

  def change do
    create constraint(:router_configs, :router_configs_default_not_archived_check,
             check: "NOT (is_default AND archived_at IS NOT NULL)"
           )

    drop index(:router_shadow_evaluations, [:shadow_config_id, :inserted_at],
           name: :router_shadow_evaluations_config_inserted_at_index
         )

    create index(:router_shadow_evaluations, [:shadow_config_id, :request_inserted_at],
             name: :router_shadow_evaluations_config_req_inserted_idx
           )

    create index(:router_shadow_evaluations, [:request_inserted_at],
             name: :router_shadow_evaluations_req_inserted_idx
           )
  end
end
