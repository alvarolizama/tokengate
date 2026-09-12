defmodule Tokengate.Providers.GroupModel do
  @moduledoc """
  Join table granting a Model to a Group (M:N).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_models" do
    # belongs_to Group — module ref resolves at runtime
    belongs_to :group, Tokengate.Accounts.Group
    belongs_to :model, Tokengate.Providers.Model

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(group_model_model, attrs) do
    group_model_model
    |> cast(attrs, [:group_id, :model_id])
    |> validate_required([:group_id, :model_id])
    |> unique_constraint([:group_id, :model_id],
      name: :group_models_group_id_model_id_index
    )
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:model_id)
  end
end
