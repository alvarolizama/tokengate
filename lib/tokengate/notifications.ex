defmodule Tokengate.Notifications do
  @moduledoc """
  The Notifications context: emits important events to Telegram and keeps the
  audit trail of what was delivered.

  ## Un solo emisor

  Todo pasa por `emit/2`. Sus responsabilidades, en orden:

    1. **Catálogo** — sólo los eventos de `Events` existen; lo demás se ignora.
    2. **Habilitado** — respeta `notification_settings.enabled_events` (con el
       default del catálogo cuando el evento no figura).
    3. **Horas de silencio** — dentro de la ventana sólo pasan los `critical`.
    4. **Anti-repetición** — cada evento tiene un cooldown; la clave de dedupe
       es `{evento, entidad}`. Esto es lo que impide que un tope reventado
       genere cientos de mensajes.
    5. **Persistencia + entrega** — inserta la `Notification` en `pending` y
       encola `TelegramWorker`. Nunca hace HTTP en línea.

  `emit/2` **jamás** lanza: se llama desde caminos calientes (proxy, budgets) y
  desde el hook de auditoría, donde una notificación rota no debe tumbar nada.

  ## Tabla ETS

  `:tokengate_notifications` — cachea los ajustes (`{:settings, row}`) y sirve de
  registro del cooldown (`{:throttle, {evento, clave}, monotonic_ms}`).
  """

  use GenServer

  import Ecto.Query, warn: false

  require Logger

  alias Tokengate.Notifications.Events
  alias Tokengate.Notifications.Link
  alias Tokengate.Notifications.Notification
  alias Tokengate.Notifications.Settings
  alias Tokengate.Notifications.TelegramWorker
  alias Tokengate.Repo

  @table :tokengate_notifications
  @settings_key {:settings}
  @default_limit 100
  @max_limit 1000

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    refresh_settings_cache()
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  @doc "Returns the singleton settings row (never nil; created by migration)."
  @spec get_settings() :: Settings.t()
  def get_settings do
    Repo.get(Settings, Settings.singleton_id()) || Repo.get!(Settings, Settings.singleton_id())
  end

  @doc "Cached settings row (falls back to the DB when the cache is cold)."
  @spec settings() :: Settings.t()
  def settings do
    case cache_lookup(@settings_key) do
      [{@settings_key, settings}] -> settings
      [] -> get_settings()
    end
  end

  @doc """
  Updates the settings row and refreshes the cache. `attrs` may carry
  `enabled_events`, `bot_username` and the quiet-hours bounds. The bot token is
  written through `put_token/1` so it is never part of a plain `cast`.
  """
  @spec update_settings(map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs) do
    result =
      get_settings()
      |> Settings.changeset(attrs)
      |> Repo.update()

    with {:ok, _settings} <- result, do: refresh_settings_cache()
    result
  end

  @doc """
  Encrypts and stores the bot token. Passing an empty string clears it (falls
  back to the env-configured token, if any).
  """
  @spec put_token(String.t()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def put_token(""), do: clear_token()

  def put_token(token) when is_binary(token) do
    result =
      get_settings()
      |> Settings.token_changeset(Tokengate.Notifications.SecretBox.encrypt(String.trim(token)))
      |> Repo.update()

    with {:ok, _settings} <- result, do: refresh_settings_cache()
    result
  end

  @doc "Clears the stored bot token."
  @spec clear_token() :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def clear_token do
    result =
      get_settings()
      |> Settings.token_changeset(nil)
      |> Repo.update()

    with {:ok, _settings} <- result, do: refresh_settings_cache()
    result
  end

  @doc "Whether `event` is enabled per the current settings."
  @spec enabled?(Events.name()) :: boolean()
  def enabled?(event) do
    case Map.get(settings().enabled_events || %{}, Atom.to_string(event)) do
      nil -> Events.default_enabled?(event)
      value -> value == true
    end
  rescue
    _ -> false
  end

  @doc "The effective enabled map (settings overlaid on the catalog defaults)."
  @spec effective_events() :: [%{name: Events.name(), enabled: boolean(), severity: String.t()}]
  def effective_events do
    for name <- Events.names_as_strings() do
      %{
        name: name,
        enabled: enabled?(String.to_existing_atom(name)),
        severity: Events.severity(String.to_existing_atom(name))
      }
    end
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Emit
  # ---------------------------------------------------------------------------

  @doc """
  Emits a notification for `event`. Fire-and-forget: returns `:ok` and never
  raises. `attrs` may carry `:entity_type`, `:entity_id`, `:target_label` and a
  `:payload` map of extras surfaced in the message.
  """
  @spec emit(Events.name(), map()) :: :ok
  def emit(event, attrs \\ %{}) do
    with {:ok, spec} <- Events.fetch(event),
         true <- enabled?(event),
         false <- quiet_hours?(spec.severity),
         false <- throttled?(event, attrs) do
      mark_throttled(event, attrs)
      persist_and_enqueue(event, spec, attrs)
    else
      _ -> :ok
    end
  rescue
    DBConnection.OwnershipError ->
      # Sin acceso a la base (p. ej. procesos de fondo bajo el sandbox de test).
      # Una notificación es best-effort: su ausencia no es un error.
      :ok

    e ->
      Logger.error("Notifications.emit/2 (#{inspect(event)}) crashed: #{inspect(e)}")
      :ok
  end

  @doc """
  Audit-action hook: maps an audited action to its event and emits. Called from
  `Tokengate.Auditing.log/6`, so it must stay cheap when the action does not
  notify (the map lookup short-circuits before any DB read).
  """
  @spec from_audit(String.t(), String.t() | nil, term(), map()) :: :ok
  def from_audit(action, entity_type, entity_id, changes) do
    case Events.from_audit_action(action) do
      nil ->
        :ok

      event ->
        emit(event, %{
          entity_type: entity_type,
          entity_id: entity_id && to_string(entity_id),
          target_label: label(changes),
          status: changes["status"] || changes[:status],
          amount_usd: changes["amount_usd"] || changes[:amount_usd]
        })
    end
  end

  defp label(changes) when is_map(changes) do
    changes["email"] || changes["name"] || changes["label"] ||
      changes[:email] || changes[:name] || changes[:label]
  end

  defp label(_), do: nil

  defp persist_and_enqueue(event, spec, attrs) do
    payload = attrs[:payload] || attrs["payload"] || %{}

    changeset =
      Notification.changeset(%Notification{}, %{
        event: Atom.to_string(event),
        severity: spec.severity,
        entity_type: attrs[:entity_type] || attrs["entity_type"],
        entity_id: attrs[:entity_id] && to_string(attrs[:entity_id]),
        target_label: attrs[:target_label] || attrs["target_label"],
        payload: stringify(payload),
        status: "pending"
      })

    case Repo.insert(changeset) do
      {:ok, notification} ->
        enqueue(notification)
        :ok

      {:error, changeset} ->
        Logger.error(
          "Notifications: could not persist #{inspect(event)}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp enqueue(%Notification{id: id}) do
    %{notification_id: id}
    |> TelegramWorker.new()
    |> Oban.insert()
  rescue
    e ->
      Logger.error("Notifications: could not enqueue delivery: #{inspect(e)}")
      :ok
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify(map), do: map

  defp stringify_value(v) when is_map(v), do: stringify(v)
  defp stringify_value(v), do: v

  # ---------------------------------------------------------------------------
  # Throttle + quiet hours
  # ---------------------------------------------------------------------------

  defp throttled?(event, attrs) do
    case Events.cooldown_ms(event) do
      0 ->
        false

      cooldown ->
        case cache_lookup(throttle_key(event, attrs)) do
          [{_key, seen_ms}] -> now_ms() - seen_ms < cooldown
          [] -> false
        end
    end
  end

  defp mark_throttled(event, attrs) do
    :ets.insert(@table, {throttle_key(event, attrs), now_ms()})
    :ok
  end

  defp throttle_key(event, attrs) do
    entity =
      attrs[:entity_id] || attrs["entity_id"] || attrs[:target_label] ||
        attrs["target_label"] || "global"

    {:throttle, {event, to_string(entity)}}
  end

  defp quiet_hours?(severity) do
    if severity == "critical" do
      false
    else
      in_quiet_hours?(settings())
    end
  end

  defp in_quiet_hours?(%Settings{quiet_hours_from: from, quiet_hours_to: to})
       when is_binary(from) and is_binary(to) do
    with {:ok, f} <- parse_time(from),
         {:ok, t} <- parse_time(to) do
      now = Time.utc_now() |> Time.truncate(:second)

      if Time.compare(f, t) == :lt do
        Time.compare(now, f) != :lt and Time.compare(now, t) == :lt
      else
        # Window wraps midnight.
        Time.compare(now, f) != :lt or Time.compare(now, t) == :lt
      end
    else
      _ -> false
    end
  end

  defp in_quiet_hours?(_), do: false

  defp parse_time(value) do
    case String.split(value, ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m),
             {:ok, time} <- Time.new(hour, minute, 0) do
          {:ok, time}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Lists notifications, newest first.

  Filters: `:event`, `:status`, `:limit` (default 100, max 1000), `:offset`.
  """
  @spec list_notifications(map()) :: [Notification.t()]
  def list_notifications(filters \\ %{}) do
    limit = filters |> get_filter(:limit) |> parse_int(@default_limit) |> min(@max_limit)
    offset = filters |> get_filter(:offset) |> parse_int(0)

    Notification
    |> filter_eq(:event, filters)
    |> filter_eq(:status, filters)
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc "Counts notifications matching the same filters (ignores limit/offset)."
  @spec count_notifications(map()) :: non_neg_integer()
  def count_notifications(filters \\ %{}) do
    Notification
    |> filter_eq(:event, filters)
    |> filter_eq(:status, filters)
    |> Repo.aggregate(:count, :id)
  end

  @doc "Gets a single notification. Raises when missing."
  def get_notification!(id), do: Repo.get!(Notification, id)

  defp get_filter(filters, field),
    do: Map.get(filters, field) || Map.get(filters, to_string(field))

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp filter_eq(query, field, filters) do
    case get_filter(filters, field) do
      nil -> query
      "" -> query
      value -> where(query, [n], field(n, ^field) == ^value)
    end
  end

  # ---------------------------------------------------------------------------
  # Telegram links
  # ---------------------------------------------------------------------------

  @doc "All linked chats, newest first."
  @spec list_links() :: [Link.t()]
  def list_links do
    Link
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  @doc "Creates a chat ↔ user link."
  @spec create_link(map()) :: {:ok, Link.t()} | {:error, Ecto.Changeset.t()}
  def create_link(attrs) do
    %Link{}
    |> Link.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Deletes a link by id."
  @spec delete_link(term()) :: :ok
  def delete_link(id) do
    case Repo.get(Link, id) do
      nil -> :ok
      link -> Repo.delete(link)
    end

    :ok
  end

  @doc "Chat ids of every linked admin — the delivery fan-out list."
  @spec linked_chat_ids() :: [String.t()]
  def linked_chat_ids do
    Link
    |> select([l], l.chat_id)
    |> Repo.all()
  end

  @doc """
  Every linked destination. A row is a chat, a group or a channel; when it is a
  forum (a channel/supergroup with topics), `thread_id` carries the
  `message_thread_id` to publish into.
  """
  @spec linked_targets() :: [Link.t()]
  def linked_targets, do: Repo.all(Link)

  # ---------------------------------------------------------------------------
  # Test/admin helpers
  # ---------------------------------------------------------------------------

  @doc "Clears every throttle mark. Test and admin use."
  @spec clear_throttle() :: :ok
  def clear_throttle do
    if :ets.whereis(@table) != :undefined do
      :ets.select_delete(@table, [{{{:throttle, :_}, :_}, [], [true]}])
    end

    :ok
  end

  @doc "Drops the settings cache and reloads it from the DB."
  @spec refresh_settings_cache() :: :ok
  def refresh_settings_cache do
    if :ets.whereis(@table) != :undefined do
      settings = get_settings()
      :ets.insert(@table, {@settings_key, settings})
    end

    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp cache_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
