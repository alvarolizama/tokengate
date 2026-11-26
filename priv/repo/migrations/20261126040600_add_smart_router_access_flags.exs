defmodule Tokengate.Repo.Migrations.AddSmartRouterAccessFlags do
  @moduledoc """
  Tri-state SmartRouter access on the three auth subjects.

  | Subject                | Column                         | Semantics                          |
  |------------------------|--------------------------------|------------------------------------|
  | `groups` (limit profile) | `router_enabled boolean NOT NULL DEFAULT false` | the profile default |
  | `group_members`        | `router_enabled boolean NULL`  | `nil` inherits · `true` forces allow · `false` forces deny |
  | `services`             | `router_enabled boolean NOT NULL DEFAULT false` | the machine consumer's own flag |

  The member column is deliberately **nullable**: a plain boolean would force an
  edit of every member row whenever the profile default changes. `nil` keeps
  the inheritance model the admin already uses for model grants
  (inherit/allow/deny), and `Accounts.router_enabled?/1` resolves it in one
  place, with the member value winning over the profile.

  `groups.router_baseline_model_id` is the profile's own savings baseline (used
  to freeze the counterfactual cost on each router request). It is
  `ON DELETE NILIFY ALL`: a baseline is optional metadata, so deleting the model
  must never block or brick the profile.

  Both columns land with constant defaults / NULL, which is a metadata-only
  operation in Postgres — no table rewrite.

  Reversible: `down/0` drops the columns (and with them the FK).
  """

  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :router_enabled, :boolean, null: false, default: false

      add :router_baseline_model_id,
          references(:models, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:group_members) do
      # Tri-state: NULL = inherit from the profile (see the moduledoc).
      add :router_enabled, :boolean
    end

    alter table(:services) do
      add :router_enabled, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:services) do
      remove :router_enabled
    end

    alter table(:group_members) do
      remove :router_enabled
    end

    alter table(:groups) do
      remove :router_baseline_model_id
      remove :router_enabled
    end
  end
end
