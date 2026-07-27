defmodule Tokengate.Repo.Migrations.DropRoutingStrategyAndWeight do
  use Ecto.Migration

  def up do
    alter table(:model_aliases) do
      remove :routing_strategy
    end

    alter table(:alias_providers) do
      remove :weight
    end
  end

  def down do
    alter table(:model_aliases) do
      add :routing_strategy, :string, null: false, default: "priority"
    end

    alter table(:alias_providers) do
      add :weight, :integer
    end
  end
end
