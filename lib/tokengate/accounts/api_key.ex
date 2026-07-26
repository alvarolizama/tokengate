defmodule Tokengate.Accounts.ApiKey do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    belongs_to :team_member, Tokengate.Accounts.TeamMember
    field :key_hash, :string
    field :key_prefix, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(team_member_id key_hash key_prefix status)a
  @required ~w(team_member_id key_hash key_prefix)a

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["active", "revoked"])
    # Only one *active* api key per team_member at a time; revoked keys may
    # coexist (partial unique index `api_keys_team_member_id_index`).
    |> unique_constraint(:team_member_id)
    |> unique_constraint(:key_hash)
    |> assoc_constraint(:team_member)
  end
end
