defmodule Tokengate.Auditing do
  @moduledoc """
  The Auditing context: append-only audit log entries.

  Records **who did what to which entity, from where and when**. System
  actions (no actor) have a `nil` user_id. Entries are written through
  `log/6`; `audit/5` is kept as a context-less convenience (no IP, no
  impersonator) for scripts and tests.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo
  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Accounts.User

  @default_limit 100
  @max_limit 1000

  # ---------------------------------------------------------------------------
  # Audit
  # ---------------------------------------------------------------------------

  @doc """
  Records an audit log entry (no request context).

  ## Arguments
    * `actor_or_nil` — a `%User{}` struct, a user_id string/uuid, or `nil`
      for system actions.
    * `action` — the action performed (e.g. `"user.create"`).
    * `entity_type` — the type of entity (e.g. `"user"`).
    * `entity_id` — the stringified id of the entity.
    * `changes` — optional map of changes (defaults to `%{}`).

  Returns `{:ok, audit_log}` or `{:error, changeset}`.
  """
  def audit(actor_or_nil, action, entity_type, entity_id, changes \\ %{}) do
    log(actor_or_nil, action, entity_type, entity_id, changes, %{})
  end

  @doc """
  Records an audit log entry with request context.

  ## Arguments
    * `actor_or_nil` — as `audit/5`.
    * `action`, `entity_type`, `entity_id`, `changes` — as `audit/5`.
    * `ctx` — a map with any of:
      * `:acting_as` — the `%User{}` whose session/scope the action ran under,
        when it differs from the actor (an impersonated user).
      * `:ip` — peer IP string (`X-Forwarded-For` aware).
      * `:user_agent` — the client User-Agent.
      * `:origin` — `"web"` (default), `"api"`, `"system"` or `"worker"`.
      * `:target_label` — human label of the entity (email, name, key prefix).

  Returns `{:ok, audit_log}` or `{:error, changeset}`.
  """
  def log(actor_or_nil, action, entity_type, entity_id, changes \\ %{}, ctx \\ %{}) do
    {user_id, actor_email, actor_role} = actor_attrs(actor_or_nil)
    acting_as = Map.get(ctx, :acting_as) || Map.get(ctx, "acting_as")

    result =
      %AuditLog{}
      |> AuditLog.changeset(%{
        user_id: user_id,
        actor_email: actor_email,
        actor_role: actor_role,
        acting_as_id: acting_as && acting_as.id,
        acting_as_email: acting_as && acting_as.email,
        action: action,
        entity_type: entity_type,
        entity_id: entity_id && to_string(entity_id),
        target_label: Map.get(ctx, :target_label),
        origin: Map.get(ctx, :origin) || "web",
        ip: Map.get(ctx, :ip),
        user_agent: Map.get(ctx, :user_agent),
        changes: changes,
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    # Un solo funnel notifica: al grabar la acción se emite su evento (si el
    # mapa de `Events` lo declara). Fire-and-forget y fuera de la transacción:
    # una notificación rota jamás debe tumbar el registro de auditoría.
    with {:ok, _audit_log} <- result do
      Tokengate.Notifications.from_audit(action, entity_type, entity_id, changes)
    end

    result
  end

  defp actor_attrs(%User{id: id, email: email, global_role: role}), do: {id, email, role}
  defp actor_attrs(id) when is_binary(id), do: {id, nil, nil}
  defp actor_attrs(_), do: {nil, nil, nil}

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Lists audit logs with optional filters.

  ## Filters (all optional)
    * `:user_id` — exact match
    * `:actor_email` — exact match
    * `:entity_type` — exact match
    * `:entity_id` — exact match
    * `:action` — exact match
    * `:target_label` — exact match
    * `:ip` — exact match
    * `:from` / `:to` — `inserted_at` range (inclusive `from`, exclusive `to`),
      DateTime/NaiveDateTime
    * `:limit` — default 100, capped at 1000
    * `:offset` — default 0

  Results are ordered by `inserted_at DESC, id DESC`.
  """
  def list_audit_logs(filters \\ %{}) do
    limit = filters |> get_filter(:limit) |> parse_int(@default_limit) |> min(@max_limit)
    offset = filters |> get_filter(:offset) |> parse_int(0)

    filters
    |> audit_logs_query()
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Builds the filtered, ordered query for `Repo.stream/2` CSV exports without a
  hard row cap.
  """
  def audit_logs_query(filters \\ %{}) do
    AuditLog
    |> maybe_where(:user_id, filters)
    |> maybe_where(:actor_email, filters)
    |> maybe_where(:entity_type, filters)
    |> maybe_where(:entity_id, filters)
    |> maybe_where(:action, filters)
    |> maybe_where(:target_label, filters)
    |> maybe_where(:ip, filters)
    |> maybe_search(filters)
    |> maybe_between(:inserted_at, get_filter(filters, :from), get_filter(filters, :to))
    |> order_by([al], desc: al.inserted_at, desc: al.id)
  end

  @doc """
  Counts audit logs matching the same filters as `list_audit_logs/1`
  (ignoring `:limit`/`:offset`). Used for pagination.
  """
  def count_audit_logs(filters \\ %{}) do
    AuditLog
    |> maybe_where(:user_id, filters)
    |> maybe_where(:actor_email, filters)
    |> maybe_where(:entity_type, filters)
    |> maybe_where(:entity_id, filters)
    |> maybe_where(:action, filters)
    |> maybe_where(:target_label, filters)
    |> maybe_where(:ip, filters)
    |> maybe_search(filters)
    |> maybe_between(:inserted_at, get_filter(filters, :from), get_filter(filters, :to))
    |> Repo.aggregate(:count, :id)
  end

  @doc "Fetches one audit log entry by UUID (returns nil for invalid/missing ids)."
  def get_audit_log(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      Repo.one(from al in AuditLog, where: al.id == ^uuid, limit: 1)
    else
      _ -> nil
    end
  end

  def get_audit_log(_), do: nil

  @doc "Common audited actions for UI autocomplete suggestions."
  def known_actions do
    ~w(
      auth.login auth.login_failed auth.logout
      impersonate.start impersonate.stop
      user.create user.update user.toggle_status user.delete
      service.create service.update service.delete
      api_key.create api_key.revoke
      group.create group.update group.delete
      topup.create topup.revoke topup.toggle_status
      provider.create provider.update provider.toggle_status provider.delete
      credential.create credential.reactivate credential.delete
      model.create model.update model.delete
      destination.create destination.update destination.delete destination.toggle
      notification.token_set notification.token_clear notification.events_update
      notification.quiet_hours_update notification.link_add notification.link_remove
      notification.resend
      settings.reset_all_usage settings.purge_expired_logs
      settings.reset_sticky_sessions settings.catalog_refresh
    )
  end

  @doc "Common audited entity types for UI autocomplete suggestions."
  def known_entity_types do
    ~w(
      session user service api_key group group_member topup
      provider credential model destination notification notification_settings
      telegram_link usage sticky_sessions catalog_providers
    )
  end

  defp get_filter(filters, field) do
    Map.get(filters, field) || Map.get(filters, to_string(field))
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp maybe_where(query, field, filters) do
    case get_filter(filters, field) do
      nil -> query
      "" -> query
      value -> where(query, [al], field(al, ^field) == ^value)
    end
  end

  defp maybe_search(query, filters) do
    case get_filter(filters, :q) do
      nil ->
        query

      "" ->
        query

      q ->
        pattern = "%#{String.trim(q)}%"

        where(
          query,
          [al],
          ilike(al.actor_email, ^pattern) or
            ilike(al.target_label, ^pattern) or
            ilike(al.action, ^pattern) or
            ilike(al.entity_type, ^pattern) or
            ilike(al.ip, ^pattern)
        )
    end
  end

  defp maybe_between(query, _field, nil, nil), do: query

  defp maybe_between(query, field, from, to) do
    query
    |> maybe_from(field, from)
    |> maybe_to(field, to)
  end

  defp maybe_from(query, _field, nil), do: query
  defp maybe_from(query, field, from), do: where(query, [al], field(al, ^field) >= ^from)

  defp maybe_to(query, _field, nil), do: query
  defp maybe_to(query, field, to), do: where(query, [al], field(al, ^field) < ^to)
end
