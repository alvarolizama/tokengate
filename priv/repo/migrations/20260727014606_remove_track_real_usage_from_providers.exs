defmodule Tokengate.Repo.Migrations.RemoveTrackRealUsageFromProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      remove :track_real_usage
    end
  end
end
