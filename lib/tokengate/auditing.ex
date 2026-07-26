defmodule Tokengate.Auditing do
  @moduledoc """
  The Auditing context: append-only audit log entries.

  Records who did what to which entity. System actions (no user) have a
  `nil` user_id.
  """

  import Ecto.Query, warn: false

  alias Tokengate.Repo
  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Accounts.User

  @default_limit 100

  # ---------------------------------------------------------------------------
  # Audit
  # ---------------------------------------------------------------------------

  @doc """
  Records an audit log entry.

  ## Arguments
    * `user_or_nil` — a `%User{}` struct, a user_id string/uuid, or `nil`
      for system actions.
    * `action` — the action performed (e.g. `"create"`, `"update"`).
    * `entity_type` — the type of entity (e.g. `"organization"`).
    * `entity_id` — the stringified id of the entity.
    * `changes` — optional map of changes (defaults to `%{}`).

  Returns `{:ok, audit_log}` or `{:error, changeset}`.
  """
  def audit(user_or_nil, action, entity_type, entity_id, changes \\ %{})

  def audit(%User{id: user_id}, action, entity_type, entity_id, changes) do
    audit(user_id, action, entity_type, entity_id, changes)
  end

  def audit(user_id, action, entity_type, entity_id, changes) when is_binary(user_id) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      user_id: user_id,
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      changes: changes
    })
    |> Repo.insert()
  end

  def audit(nil, action, entity_type, entity_id, changes) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      user_id: nil,
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      changes: changes
    })
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Lists audit logs with optional filters.

  ## Filters (all optional)
    * `:user_id` — exact match
    * `:entity_type` — exact match
    * `:action` — exact match

  Results are ordered by `inserted_at DESC`, limited to 100 by default.
  """
  def list_audit_logs(filters \\ %{}) do
    limit = Map.get(filters, :limit) || Map.get(filters, "limit") || @default_limit

    AuditLog
    |> maybe_where(:user_id, filters)
    |> maybe_where(:entity_type, filters)
    |> maybe_where(:action, filters)
    |> order_by([al], desc: al.inserted_at, desc: al.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_where(query, field, filters) do
    value = Map.get(filters, field) || Map.get(filters, to_string(field))

    if is_nil(value), do: query, else: where(query, [al], field(al, ^field) == ^value)
  end
end
