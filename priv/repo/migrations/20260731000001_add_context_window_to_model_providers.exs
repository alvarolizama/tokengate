defmodule Tokengate.Repo.Migrations.AddContextWindowToModelProviders do
  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      add :context_window, :integer
    end
  end
end
