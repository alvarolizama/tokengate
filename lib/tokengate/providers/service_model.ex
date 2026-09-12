defmodule Tokengate.Providers.ServiceModel do
  @moduledoc """
  Join table granting a Model to a Service (M:N).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_models" do
    belongs_to :service, Tokengate.Accounts.Service
    belongs_to :model, Tokengate.Providers.Model

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service_model_model, attrs) do
    service_model_model
    |> cast(attrs, [:service_id, :model_id])
    |> validate_required([:service_id, :model_id])
    |> unique_constraint([:service_id, :model_id],
      name: :service_models_service_id_model_id_index
    )
    |> foreign_key_constraint(:service_id)
    |> foreign_key_constraint(:model_id)
  end
end
