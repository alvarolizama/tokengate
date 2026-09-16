defmodule Tokengate.Providers.GroupMemberDeniedModel do
  @moduledoc """
  Join table revoking an individual GroupMember access to a Model the
  group already granted (M:N). Effective access = (group ∪ extras) − denied.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_member_denied_models" do
    # belongs_to GroupMember — module ref resolves at runtime
    belongs_to :group_member, Tokengate.Accounts.GroupMember
    belongs_to :model, Tokengate.Providers.Model

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(group_member_denied_model, attrs) do
    group_member_denied_model
    |> cast(attrs, [:group_member_id, :model_id])
    |> validate_required([:group_member_id, :model_id])
    |> unique_constraint([:group_member_id, :model_id],
      name: :group_member_denied_models_group_member_id_model_id_index
    )
    |> foreign_key_constraint(:group_member_id)
    |> foreign_key_constraint(:model_id)
  end
end
