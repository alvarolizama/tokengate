defmodule Tokengate.Providers.ServiceModelAlias do
  @moduledoc """
  Join table granting a ModelAlias to a Service (M:N).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_model_aliases" do
    belongs_to :service, Tokengate.Accounts.Service
    belongs_to :model_alias, Tokengate.Providers.ModelAlias

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service_model_alias, attrs) do
    service_model_alias
    |> cast(attrs, [:service_id, :model_alias_id])
    |> validate_required([:service_id, :model_alias_id])
    |> unique_constraint([:service_id, :model_alias_id],
      name: :service_model_aliases_service_id_model_alias_id_index
    )
    |> foreign_key_constraint(:service_id)
    |> foreign_key_constraint(:model_alias_id)
  end
end
