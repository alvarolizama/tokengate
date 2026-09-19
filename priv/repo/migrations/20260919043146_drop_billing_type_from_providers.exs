defmodule Tokengate.Repo.Migrations.DropBillingTypeFromProviders do
  @moduledoc """
  Drops `providers.billing_type`.

  The column was a cache of a **code-owned** label (`Catalog.billing/1`, keyed
  by the provider key), not data models.dev publishes. Nothing reads it
  anymore:

    * the admin UI never showed it as an editable field, and its only visible
      surface — the "Billing" column of a model's assigned providers — is gone;
    * routing, priority ranking and per-call cost were already decoupled from
      it (pinned by tests: "billing surface no longer exempts" / "does not
      rank" / "no billing-surface exemption");
    * its last reader was `Tokengate.Logs.CostBackfill`, a module with no
      callers, removed together with this column.

  So this is a pure removal: no replacement field and no behaviour change.
  """
  use Ecto.Migration

  def change do
    alter table(:providers) do
      remove :billing_type, :string, default: "pay_per_token"
    end
  end
end
