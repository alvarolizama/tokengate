defmodule Tokengate.Accounts.GroupMember do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_members" do
    belongs_to :user, Tokengate.Accounts.User
    belongs_to :group, Tokengate.Accounts.Group
    field :extra_concurrency, :integer
    field :extra_rpm, :integer
    field :status, :string, default: "active"

    # Virtual field populated only on the service "virtual member" built by
    # `TokengateWeb.Plugs.ApiAuth.service_to_virtual_member/1`. Carries the
    # service name so the proxy can snapshot it into in-flight entries.
    field :service_name, :string, virtual: true

    has_one :api_key, Tokengate.Accounts.ApiKey

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(user_id group_id extra_concurrency extra_rpm status)a
  @required ~w(user_id group_id)a

  def changeset(group_member, attrs) do
    group_member
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["active", "suspended"])
    |> validate_number(:extra_concurrency, greater_than: 0)
    |> validate_number(:extra_rpm, greater_than: 0)
    |> unique_constraint(:group_id, name: :group_members_user_group_unique_index)
    |> assoc_constraint(:user)
    |> assoc_constraint(:group)
  end
end
