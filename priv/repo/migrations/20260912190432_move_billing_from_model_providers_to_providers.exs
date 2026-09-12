defmodule Tokengate.Repo.Migrations.MoveBillingFromModelProvidersToProviders do
  @moduledoc """
  Billing is a provider-level attribute now that the catalog splits
  subscription vs pay-per-token surfaces into separate provider entries.

  * `providers.billing_type` (existing, default "pay_per_token") becomes the
    single source of truth. Backfill builtins from model_providers rows
    marked `included` (customs default to pay_per_token) and then again from
    the catalog values compiled into this migration.
  * `model_providers.billing_mode` is dropped: routing/cost/sticky derive it
    from `credential.provider.billing_type`.

  Mapping: provider billing "subscription" == routing billing_mode
  "included"; "pay_per_token" maps to itself.
  """
  use Ecto.Migration

  # Catalog billing per builtin key, mirrored from
  # Tokengate.Providers.Catalog at migration time.
  @catalog_billing %{
    "openrouter" => "pay_per_token",
    "fireworks" => "pay_per_token",
    "qwen_cloud" => "pay_per_token",
    "qwen_cloud_token_plan" => "subscription",
    "opencode_zen" => "pay_per_token",
    "opencode_go" => "subscription",
    "kimi" => "pay_per_token",
    "kimi_code" => "subscription",
    "zai" => "pay_per_token",
    "zai_coding_plan" => "subscription",
    "abliteration" => "pay_per_token",
    "crof_ai" => "pay_per_token",
    "nube" => "pay_per_token"
  }

  def up do
    # 1. Backfill providers.billing_type from existing model_providers that
    #    were marked "included" — operator intent for subscription surfaces.
    execute """
    UPDATE providers p
    SET billing_type = 'subscription'
    WHERE EXISTS (
      SELECT 1
      FROM model_providers mp
      JOIN provider_credentials c ON c.id = mp.credential_id
      WHERE c.provider_id = p.id
        AND mp.billing_mode = 'included'
    )
    """

    # 2. Catalog billing wins for builtins.
    for {key, billing} <- @catalog_billing do
      execute """
      UPDATE providers
      SET billing_type = '#{billing}'
      WHERE key = '#{key}'
      """
    end

    # 3. Drop the per-model billing column.
    alter table(:model_providers) do
      remove :billing_mode
    end
  end

  def down do
    alter table(:model_providers) do
      add :billing_mode, :string, null: false, default: "pay_per_token"
    end

    # Recompute billing_mode from the provider surface.
    execute """
    UPDATE model_providers mp
    SET billing_mode = CASE
      WHEN c.provider_id IS NULL THEN 'pay_per_token'
      WHEN p.billing_type = 'subscription' THEN 'included'
      ELSE 'pay_per_token'
    END
    FROM provider_credentials c
    LEFT JOIN providers p ON p.id = c.provider_id
    WHERE c.id = mp.credential_id
    """
  end
end
