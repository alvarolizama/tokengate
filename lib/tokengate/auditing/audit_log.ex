defmodule Tokengate.Auditing.AuditLog do
  @moduledoc """
  An audit log entry recording who did what to which entity, and from where.

  The table is a native Postgres RANGE-partitioned table on `inserted_at`
  (monthly partitions, see `Tokengate.Auditing.PartitionWorker`) and is
  **append-only**: a DB trigger rejects `UPDATE`/`DELETE`. The schema only
  inserts and queries — never updates or deletes.

  System actions (no actor) have a `nil` user_id. `actor_email`/`actor_role`
  are denormalized so attribution survives the `ON DELETE SET NULL` on
  `user_id` when a user is deleted.

  The **actor is always the responsible human**: the admin when the entry was
  made under an impersonation session, otherwise the signed-in user. The
  impersonated user is recorded separately in `acting_as_id`/`acting_as_email`
  (nil unless impersonating).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field :id, :binary_id, primary_key: true, autogenerate: true
    field :inserted_at, :utc_datetime, primary_key: true

    field :actor_email, :string
    field :actor_role, :string
    field :acting_as_id, :binary_id
    field :acting_as_email, :string
    field :action, :string
    field :entity_type, :string
    field :entity_id, :string
    field :target_label, :string
    field :origin, :string, default: "web"
    field :ip, :string
    field :user_agent, :string
    field :changes, :map, default: %{}

    belongs_to :user, Tokengate.Accounts.User
  end

  @permitted ~w(user_id actor_email actor_role acting_as_id acting_as_email
    action entity_type entity_id target_label origin ip user_agent changes
    inserted_at)a
  @required ~w(action entity_type entity_id)a

  @doc false
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> foreign_key_constraint(:user_id)
  end
end
