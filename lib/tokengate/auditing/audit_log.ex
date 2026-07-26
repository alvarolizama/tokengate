defmodule Tokengate.Auditing.AuditLog do
  @moduledoc """
  An audit log entry recording who did what to which entity.

  System actions (no user) have a `nil` user_id. The `entity_id` is a
  stringified id of any entity (UUID or otherwise). The `changes` map
  captures what changed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :string
    field :changes, :map, default: %{}

    belongs_to :user, Tokengate.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @permitted ~w(user_id action entity_type entity_id changes)a
  @required ~w(action entity_type entity_id)a

  @doc false
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> foreign_key_constraint(:user_id)
  end
end
