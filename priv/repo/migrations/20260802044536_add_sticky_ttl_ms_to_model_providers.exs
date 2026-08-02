defmodule Tokengate.Repo.Migrations.AddStickyTtlMsToModelProviders do
  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      add :sticky_ttl_ms, :integer
    end
  end
end
