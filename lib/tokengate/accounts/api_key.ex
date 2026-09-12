defmodule Tokengate.Accounts.ApiKey do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    belongs_to :group_member, Tokengate.Accounts.GroupMember
    field :key_hash, :string
    field :key_prefix, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(group_member_id key_hash key_prefix status)a
  @required ~w(group_member_id key_hash key_prefix)a

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["active", "revoked"])
    # One api key per group_member (full unique index
    # `api_keys_group_member_id_index`); `replace_api_key/1` rotates in place.
    |> unique_constraint(:group_member_id)
    |> unique_constraint(:key_hash)
    |> assoc_constraint(:group_member)
  end
end
