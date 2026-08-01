defmodule Tokengate.Repo.Migrations.CreateServiceSupervisors do
  use Ecto.Migration

  def change do
    create table(:service_supervisors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_supervisors, [:service_id, :user_id])
    create index(:service_supervisors, [:user_id])
  end
end
