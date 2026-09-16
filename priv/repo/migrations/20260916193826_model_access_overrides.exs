defmodule Tokengate.Repo.Migrations.ModelAccessOverrides do
  @moduledoc """
  Tabla `group_member_denied_models`: override individual que QUITA modelos
  del acceso que el grupo ya le dio a un miembro. El acceso efectivo a
  modelos es (grupo ∪ extras) − denegados.
  """
  use Ecto.Migration

  def up do
    create table(:group_member_denied_models, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_member_id,
          references(:group_members, type: :binary_id, on_delete: :delete_all),
          null: false

      add :model_id, references(:models, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_member_denied_models, [:group_member_id, :model_id],
             name: :group_member_denied_models_group_member_id_model_id_index
           )
  end

  def down do
    drop table(:group_member_denied_models)
  end
end
