defmodule Tokengate.Repo.Migrations.RemoveContextWindowFromModelProviders do
  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      remove :context_window
    end
  end
end
