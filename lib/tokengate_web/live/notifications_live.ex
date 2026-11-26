defmodule TokengateWeb.NotificationsLive do
  @moduledoc """
  Admin-only section for Telegram notifications.

  Cuatro tarjetas en un solo lugar:

    * **Bot** — token (cifrado / env), `getMe`, envío de prueba.
    * **Eventos** — qué se notifica (con su severidad y cooldown).
    * **Horas de silencio** — ventana UTC en la que sólo pasan los `critical`.
    * **Chats vinculados** — qué Telegram pertenece a qué admin.

  Más abajo, el **registro de envíos**: cada evento emitido, su estado y el
  reenvío manual. La sección nace como una LiveView admin más (mismo gate y
  `require_admin_hook` de defensa en profundidad que `ObservabilityLive`).
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents

  @per_page 25

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Events
  alias Tokengate.Notifications.Telegram

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user && user.global_role == "admin" do
      socket =
        socket
        |> assign(:page_title, gettext("Notifications") <> " · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:token, "")
        |> assign(:per_page, @per_page)
        |> assign(:page, 1)
        |> assign(:total_notifications, 0)
        |> assign(:total_pages, 1)
        |> assign(:log_filters, %{"status" => "", "event" => ""})
        |> assign(:log_filter_form, to_form(%{"status" => "", "event" => ""}, as: :nf))
        |> assign(:deliveries_by_id, %{})
        |> assign(:error_detail, nil)
        |> assign(:settings, %{bot_username: nil, bot_token: nil})
        |> assign(:events, [])
        |> assign(:env_token?, false)
        |> assign(:token_set?, false)
        |> assign(:configured?, false)
        |> assign(:links_empty?, true)
        |> assign(:notifications_empty?, true)
        |> stream(:links, [], reset: true)
        |> stream(:notifications, [], reset: true)
        |> assign(:link_form, link_form())
        |> assign(:quiet_form, to_form(%{"from" => "", "to" => ""}, as: :quiet))

      socket =
        if connected?(socket) do
          Notifications.subscribe()

          socket
          |> assign(:quiet_form, quiet_form())
          |> load_data()
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: "/dashboard")}
    end
  end

  # Defense-in-depth: the router gates this LiveView behind live_session :admin,
  # but a malicious client could fire events directly over the WebSocket.
  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
      end
    end)
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket) do
    settings = Notifications.get_settings()
    links = Notifications.list_links()

    socket
    |> assign(:settings, settings)
    |> assign(:events, Notifications.effective_events())
    |> assign(:env_token?, is_binary(Application.get_env(:tokengate, :telegram_bot_token)))
    |> assign(:token_set?, not is_nil(settings.bot_token))
    |> assign(:configured?, Telegram.configured?())
    |> assign(:links_empty?, links == [])
    |> stream(:links, links, reset: true)
    |> load_notifications()
  end

  defp load_notifications(socket) do
    filters = socket.assigns.log_filters
    per_page = socket.assigns.per_page
    query_filters = %{status: filters["status"], event: filters["event"]}

    total = Notifications.count_notifications(query_filters)
    total_pages = max(ceil(total / per_page), 1)
    page = min(socket.assigns.page, total_pages)

    notifications =
      Notifications.list_notifications(
        Map.merge(query_filters, %{limit: per_page, offset: (page - 1) * per_page})
      )

    deliveries_by_id =
      notifications
      |> Enum.map(& &1.id)
      |> Notifications.list_deliveries_by_notification()

    socket
    |> assign(:page, page)
    |> assign(:total_notifications, total)
    |> assign(:total_pages, total_pages)
    |> assign(:deliveries_by_id, deliveries_by_id)
    |> assign(:notifications_empty?, notifications == [])
    |> stream(:notifications, notifications, reset: true)
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("save_token", %{"token" => %{"bot_token" => token}}, socket) do
    if blank_token?(token) do
      # The token input is never prefilled, so an empty submit means "keep the
      # current one" (as the hint says). Clearing has its own button and event:
      # an empty save used to DELETE the stored token.
      {:noreply,
       socket
       |> assign(:token, "")
       |> put_flash(:info, gettext("No new token submitted: the stored one is kept."))}
    else
      case Notifications.put_token(token) do
        {:ok, _} ->
          audit(socket, "notification.token_set", "notification_settings", "global", %{})

          {:noreply,
           socket
           |> put_flash(:info, gettext("Bot token saved."))
           |> maybe_resolve_username()
           |> load_data()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save the bot token."))}
      end
    end
  end

  def handle_event("save_token", _params, socket), do: {:noreply, socket}

  def handle_event("clear_token", _params, socket) do
    Notifications.clear_token()
    audit(socket, "notification.token_clear", "notification_settings", "global", %{})

    {:noreply,
     socket
     |> put_flash(:info, gettext("Stored bot token removed."))
     |> load_data()}
  end

  def handle_event("test_message", _params, socket) do
    flash =
      case Notifications.linked_targets() do
        [] ->
          {:error, gettext("No linked chats: add one before testing.")}

        targets ->
          results =
            targets
            |> Task.async_stream(
              &{&1, Telegram.send_message(&1.chat_id, message(:test), thread_opts(&1))},
              max_concurrency: 5,
              timeout: 10_000,
              on_timeout: :kill_task
            )
            |> Enum.map(fn
              {:ok, item} -> item
              {:exit, _reason} -> {nil, {:error, :timeout}}
            end)

          case Enum.find(results, fn {_t, res} -> match?({:ok, _}, res) end) do
            {_t, {:ok, _}} -> {:info, gettext("Test message sent.")}
            _ -> {:error, gettext("Telegram rejected the test message.")}
          end
      end

    {kind, text} = flash
    {:noreply, put_flash(socket, kind, text)}
  end

  def handle_event("toggle_event", %{"event" => name}, socket) do
    enabled = Map.new(Notifications.effective_events(), fn e -> {e.name, e.enabled} end)
    flipped = Map.update(enabled, name, true, &(not &1))
    stringified = Map.new(flipped, fn {k, v} -> {to_string(k), v} end)

    case Notifications.update_settings(%{"enabled_events" => stringified}) do
      {:ok, _} ->
        audit(socket, "notification.events_update", "notification_settings", "global", %{
          "event" => name
        })

        {:noreply, load_data(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the events."))}
    end
  end

  def handle_event("save_quiet_hours", %{"quiet" => params}, socket) do
    attrs = %{
      "quiet_hours_from" => blank_to_nil(params["from"]),
      "quiet_hours_to" => blank_to_nil(params["to"])
    }

    case Notifications.update_settings(attrs) do
      {:ok, _} ->
        audit(socket, "notification.quiet_hours_update", "notification_settings", "global", attrs)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Quiet hours updated."))
         |> load_data()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Set both bounds or leave both empty."))}
    end
  end

  def handle_event("add_link", %{"link" => params}, socket) do
    attrs =
      %{
        "chat_id" => String.trim(params["chat_id"] || ""),
        "kind" => params["kind"] || "chat",
        "thread_id" => params["thread_id"],
        "label" => blank_to_nil(params["label"])
      }

    create_link(socket, attrs)
  end

  def handle_event("remove_link", %{"id" => id}, socket) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      Notifications.delete_link(uuid)
      audit(socket, "notification.link_remove", "telegram_link", uuid, %{})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Chat removed."))
       |> load_data()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Link not found."))}
    end
  end

  def handle_event("resend", %{"id" => id}, socket) do
    case Notifications.resend_notification(id) do
      {:ok, notification} ->
        audit(socket, "notification.resend", "notification", notification.id, %{
          "event" => notification.event
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Resend queued."))
         |> load_notifications()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Notification not found."))}
    end
  end

  def handle_event("refresh_log", _params, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_event("filter_notifications", %{"nf" => params}, socket) do
    filters = %{
      "status" => Map.get(params, "status", ""),
      "event" => Map.get(params, "event", "")
    }

    {:noreply,
     socket
     |> assign(:log_filters, filters)
     |> assign(:log_filter_form, to_form(filters, as: :nf))
     |> assign(:page, 1)
     |> load_notifications()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    parsed =
      case Integer.parse(to_string(page)) do
        {n, ""} -> max(n, 1)
        _ -> socket.assigns.page
      end

    {:noreply,
     socket
     |> assign(:page, parsed)
     |> load_notifications()}
  end

  def handle_event("show_error", %{"id" => id}, socket) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Notifications.get_notification(uuid) do
          nil ->
            {:noreply, socket}

          notification ->
            deliveries = Notifications.list_deliveries_by_notification([notification.id])

            {:noreply,
             assign(socket, :error_detail, %{
               notification: notification,
               deliveries: Map.get(deliveries, notification.id, [])
             })}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_error", _params, socket) do
    {:noreply, assign(socket, :error_detail, nil)}
  end

  @impl true
  def handle_info({:notification_updated, _notification}, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers --------------------------------------------------------------

  defp create_link(socket, attrs) do
    case Notifications.create_link(attrs) do
      {:ok, link} ->
        audit(socket, "notification.link_add", "telegram_link", link.id, %{
          "chat_id" => link.chat_id
        })

        {:noreply,
         socket
         |> assign(:link_form, link_form())
         |> put_flash(:info, gettext("Chat linked."))
         |> load_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :link_form, to_form(changeset, as: :link))}
    end
  end

  defp maybe_resolve_username(socket) do
    case Telegram.get_me() do
      {:ok, username} ->
        Notifications.update_settings(%{"bot_username" => username})
        socket

      _ ->
        socket
    end
  end

  defp link_form,
    do: to_form(%{"chat_id" => "", "kind" => "chat", "thread_id" => "", "label" => ""}, as: :link)

  defp quiet_form do
    settings = Notifications.get_settings()

    to_form(
      %{
        "from" => settings.quiet_hours_from || "",
        "to" => settings.quiet_hours_to || ""
      },
      as: :quiet
    )
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)
  defp blank_to_nil(value), do: value

  defp blank_token?(token) when is_binary(token), do: String.trim(token) == ""
  defp blank_token?(_), do: true

  defp message(:test), do: gettext("Tokengate test message — notifications are wired up.")

  defp thread_opts(%{thread_id: nil}), do: []
  defp thread_opts(%{thread_id: thread_id}), do: [message_thread_id: thread_id]

  defp severity_badge("critical"), do: {"badge-error", gettext("Critical")}
  defp severity_badge("warning"), do: {"badge-warning", gettext("Warning")}
  defp severity_badge("security"), do: {"badge-info", gettext("Security")}
  defp severity_badge(_), do: {"badge-ghost", gettext("Info")}

  defp status_badge("sent"), do: {"badge-success", gettext("Sent")}
  defp status_badge("failed"), do: {"badge-error", gettext("Failed")}
  defp status_badge(_), do: {"badge-warning", gettext("Pending")}

  defp kind_label("channel"), do: gettext("Channel")
  defp kind_label("group"), do: gettext("Group")
  defp kind_label(_), do: gettext("Chat")

  defp event_label("credential_disabled"), do: gettext("Provider credential disabled")
  defp event_label("global_daily_cap_reached"), do: gettext("Global daily cap reached")
  defp event_label("breaker_opened"), do: gettext("Circuit breaker opened")
  defp event_label("subject_limit_reached"), do: gettext("Monthly limit reached")
  defp event_label("no_credit"), do: gettext("No spending path")
  defp event_label("topup_changed"), do: gettext("Top-up changed")
  defp event_label("credential_reactivated"), do: gettext("Provider credential reactivated")
  defp event_label("user_created"), do: gettext("User created")
  defp event_label("service_created"), do: gettext("Service created")
  defp event_label("api_key_changed"), do: gettext("API key changed")
  defp event_label("impersonation_started"), do: gettext("Impersonation started")
  defp event_label(other), do: other

  defp event_description("credential_disabled"),
    do:
      gettext(
        "A provider credential was disabled after a 401/402/403 (bad key, no credit, forbidden)."
      )

  defp event_description("global_daily_cap_reached"),
    do:
      gettext(
        "The global daily spend cap was reached; new requests are rejected until UTC midnight."
      )

  defp event_description("breaker_opened"),
    do: gettext("A provider circuit breaker tripped after consecutive failures.")

  defp event_description("subject_limit_reached"),
    do: gettext("A subject exhausted its monthly limit and has no usable top-up.")

  defp event_description("no_credit"),
    do: gettext("A subject has no spending path at all: no limit, not unlimited, no top-ups.")

  defp event_description("topup_changed"),
    do: gettext("An admin created, revoked or toggled a credit top-up.")

  defp event_description(_), do: ""

  defp quiet_local_hint(quiet_form, timezone) when timezone not in [nil, "", "Etc/UTC"] do
    from_str = quiet_form[:from].value
    to_str = quiet_form[:to].value

    with true <- is_binary(from_str) and from_str != "",
         true <- is_binary(to_str) and to_str != "",
         {:ok, from_t} <- parse_hhmm(from_str),
         {:ok, to_t} <- parse_hhmm(to_str),
         today <- Date.utc_today(),
         {:ok, f_utc} <- DateTime.new(today, from_t, "Etc/UTC"),
         {:ok, t_utc} <- DateTime.new(today, to_t, "Etc/UTC") do
      "#{format_time(f_utc, timezone)} – #{format_time(t_utc, timezone)} (#{timezone})"
    else
      _ -> nil
    end
  end

  defp quiet_local_hint(_quiet_form, _timezone), do: nil

  defp parse_hhmm(str) do
    case String.split(str, ":") do
      [h, m] ->
        with {hh, ""} <- Integer.parse(h),
             {mm, ""} <- Integer.parse(m),
             {:ok, time} <- Time.new(hh, mm, 0) do
          {:ok, time}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp format_time(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M")
      _ -> Calendar.strftime(dt, "%H:%M")
    end
  end

  defp event_options do
    Enum.map(Events.names_as_strings(), fn name -> {event_label(name), name} end)
  end

  ## Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          {gettext("Notifications")}
          <:subtitle>
            {gettext("Telegram alerts for important events across the gateway")}
          </:subtitle>
        </.header>

        <%!-- Bot --%>
        <.section
          id="notifications-bot-card"
          title={gettext("Bot")}
          icon="hero-paper-airplane"
        >
          <div class="space-y-3">
            <div class="flex flex-wrap items-center gap-2 text-sm">
              <span class={[
                "badge badge-sm",
                if(@configured?, do: "badge-success", else: "badge-error")
              ]}>
                {if @configured?, do: gettext("Configured"), else: gettext("Not configured")}
              </span>

              <span :if={@env_token?} class="badge badge-sm badge-info">
                {gettext("Token from environment")}
              </span>

              <span :if={@token_set?} class="badge badge-sm badge-ghost">
                {gettext("Stored token set")}
              </span>

              <span :if={@settings.bot_username} class="text-base-content/60">
                @{@settings.bot_username}
              </span>
            </div>

            <p :if={@env_token?} class="text-xs text-base-content/50">
              {gettext(
                "The token comes from the TELEGRAM_BOT_TOKEN environment variable and takes precedence over the stored one."
              )}
            </p>

            <.form for={%{}} id="notifications-token-form" phx-submit="save_token">
              <.input
                name="token[bot_token]"
                type="password"
                label={gettext("Bot token")}
                value={@token}
                autocomplete="off"
                hint={gettext("Stored encrypted. Leave empty to keep the current one.")}
              />
              <div class="flex flex-wrap gap-2 mt-3">
                <button type="submit" class="btn btn-primary btn-sm" id="save-token-btn">
                  {gettext("Save token")}
                </button>
                <button
                  type="button"
                  phx-click="test_message"
                  class="btn btn-ghost btn-sm"
                  id="test-message-btn"
                >
                  {gettext("Send test")}
                </button>
                <button
                  :if={@token_set?}
                  type="button"
                  phx-click="clear_token"
                  data-confirm={gettext("Remove stored bot token?")}
                  class="btn btn-ghost btn-sm text-error"
                  id="clear-token-btn"
                >
                  {gettext("Remove stored token")}
                </button>
              </div>
            </.form>
          </div>
        </.section>

        <%!-- Events --%>
        <.section
          id="notifications-events-card"
          title={gettext("Events")}
          icon="hero-list-bullet"
          caption={
            gettext(
              "Choose which events are delivered to Telegram. Each has its own anti-repeat window."
            )
          }
        >
          <div class="overflow-x-auto">
            <.table
              id="events-rows"
              rows={@events}
              row_id={fn event -> "event-row-" <> event.name end}
            >
              <:col :let={event} label={gettext("Event")}>
                <div class="font-medium text-sm">{event_label(event.name)}</div>
                <div
                  :if={event_description(event.name) != ""}
                  class="text-xs text-base-content/50"
                >
                  {event_description(event.name)}
                </div>
              </:col>
              <:col :let={event} label={gettext("Severity")}>
                <% {cls, text} = severity_badge(event.severity) %>
                <span class={"badge badge-sm " <> cls}>{text}</span>
              </:col>
              <:col :let={event} label={gettext("Enabled")} align="right">
                <button
                  type="button"
                  phx-click="toggle_event"
                  phx-value-event={event.name}
                  id={"toggle-event-" <> event.name}
                  class={[
                    "btn btn-xs",
                    if(event.enabled, do: "btn-success", else: "btn-ghost")
                  ]}
                >
                  {if event.enabled, do: gettext("On"), else: gettext("Off")}
                </button>
              </:col>
            </.table>
          </div>
        </.section>

        <%!-- Quiet hours --%>
        <.section
          id="notifications-quiet-card"
          title={gettext("Quiet hours")}
          icon="hero-moon"
          caption={
            gettext(
              "Within this UTC window only critical events are delivered. Leave both empty to disable."
            )
          }
        >
          <div class="space-y-2">
            <.form
              for={@quiet_form}
              id="quiet-hours-form"
              phx-submit="save_quiet_hours"
              class="flex flex-wrap gap-2 items-end"
            >
              <.input
                field={@quiet_form[:from]}
                type="time"
                label={gettext("From")}
                class="input input-sm"
              />
              <.input
                field={@quiet_form[:to]}
                type="time"
                label={gettext("To")}
                class="input input-sm"
              />
              <button type="submit" class="btn btn-primary btn-sm mb-2" id="save-quiet-btn">
                {gettext("Save")}
              </button>
            </.form>
            <p
              :if={local_hint = quiet_local_hint(@quiet_form, @timezone)}
              class="text-xs text-base-content/50"
              id="quiet-local-hint"
            >
              {gettext("Local equivalent:")} <span class="font-mono">{local_hint}</span>
            </p>
          </div>
        </.section>

        <%!-- Linked chats --%>
        <.section
          id="notifications-links-card"
          title={gettext("Linked chats")}
          icon="hero-user-group"
          caption={
            gettext(
              "Chats and channels that receive the notifications. The chat id is the number Telegram shows for the conversation."
            )
          }
        >
          <div class="space-y-3">
            <.form
              for={@link_form}
              id="link-form"
              phx-submit="add_link"
              class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-12 gap-3 items-end"
            >
              <div class="lg:col-span-2">
                <.input
                  field={@link_form[:kind]}
                  type="select"
                  label={gettext("Kind")}
                  class="w-full select select-sm"
                  options={[
                    {gettext("Chat"), "chat"},
                    {gettext("Group"), "group"},
                    {gettext("Channel"), "channel"}
                  ]}
                />
              </div>
              <div class="lg:col-span-3">
                <.input
                  field={@link_form[:chat_id]}
                  type="text"
                  label={gettext("Chat id")}
                  class="w-full input input-sm"
                />
              </div>
              <div class="lg:col-span-2">
                <.input
                  field={@link_form[:thread_id]}
                  type="text"
                  label={gettext("Topic id")}
                  class="w-full input input-sm"
                />
              </div>
              <div class="lg:col-span-3">
                <.input
                  field={@link_form[:label]}
                  type="text"
                  label={gettext("Label")}
                  class="w-full input input-sm"
                />
              </div>
              <div class="sm:col-span-2 lg:col-span-2">
                <button type="submit" class="btn btn-primary btn-sm w-full mb-2" id="add-link-btn">
                  {gettext("Link")}
                </button>
              </div>
            </.form>

            <p class="text-xs text-base-content/50">
              {gettext(
                "For a channel, add the bot as an administrator; a negative chat id (-100…) is normal. The topic id is only needed for a channel/group with topics."
              )}
            </p>

            <div class="overflow-x-auto">
              <.table
                id="links"
                rows={@streams.links}
                row_item={fn {_id, link} -> link end}
                empty?={@links_empty?}
              >
                <:col :let={link} label={gettext("Kind")}>
                  <span class="badge badge-sm badge-ghost">{kind_label(link.kind)}</span>
                </:col>
                <:col :let={link} label={gettext("Chat id")}>
                  <span class="font-mono text-xs">{link.chat_id}</span>
                </:col>
                <:col :let={link} label={gettext("Topic id")}>
                  <span class="font-mono text-xs">{link.thread_id}</span>
                </:col>
                <:col :let={link} label={gettext("Label")}>
                  <span class="text-sm">{link.label}</span>
                </:col>
                <:action :let={link}>
                  <button
                    type="button"
                    phx-click="remove_link"
                    phx-value-id={link.id}
                    data-confirm={gettext("Remove this linked chat?")}
                    class="btn btn-ghost btn-xs text-error"
                    id={"remove-link-" <> link.id}
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Remove")}
                  </button>
                </:action>
                <:empty>
                  <.icon name="hero-link-slash" class="w-8 h-8 mx-auto mb-2 opacity-40" />
                  <p class="text-sm">{gettext("No linked chats yet.")}</p>
                </:empty>
              </.table>
            </div>
          </div>
        </.section>

        <%!-- Delivery log --%>
        <.section
          id="notifications-log-card"
          title={gettext("Delivery log")}
          icon="hero-inbox"
          caption={gettext("Emitted notifications and per-chat delivery status.")}
        >
          <div class="space-y-3">
            <div class="flex flex-wrap items-end justify-between gap-3">
              <.form
                for={@log_filter_form}
                id="notifications-filter-form"
                phx-change="filter_notifications"
                class="flex flex-wrap items-end gap-2"
              >
                <div class="w-40">
                  <.input
                    field={@log_filter_form[:status]}
                    type="select"
                    prompt={gettext("All statuses")}
                    options={[
                      {gettext("Sent"), "sent"},
                      {gettext("Pending"), "pending"},
                      {gettext("Failed"), "failed"}
                    ]}
                    class="select select-sm w-full"
                  />
                </div>
                <div class="w-56">
                  <.input
                    field={@log_filter_form[:event]}
                    type="select"
                    prompt={gettext("All events")}
                    options={event_options()}
                    class="select select-sm w-full"
                  />
                </div>
              </.form>

              <button
                type="button"
                phx-click="refresh_log"
                class="btn btn-ghost btn-xs mb-2"
                id="refresh-log-btn"
              >
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Refresh")}
              </button>
            </div>

            <div class="overflow-x-auto">
              <.table
                id="notifications"
                rows={@streams.notifications}
                row_item={fn {_id, notification} -> notification end}
                empty?={@notifications_empty?}
              >
                <:col :let={n} label={gettext("When")}>
                  <span class="text-xs text-base-content/60 whitespace-nowrap">
                    {format_datetime_short(n.inserted_at, @timezone)}
                  </span>
                </:col>
                <:col :let={n} label={gettext("Event")}>
                  <div class="text-sm">{event_label(n.event)}</div>
                  <div :if={n.target_label} class="text-xs text-base-content/50">
                    {n.target_label}
                  </div>
                </:col>
                <:col :let={n} label={gettext("Chats")}>
                  <% deliveries = Map.get(@deliveries_by_id, n.id, []) %>
                  <%= if deliveries == [] do %>
                    <span class="text-xs text-base-content/40">—</span>
                  <% else %>
                    <div class="flex flex-wrap gap-1">
                      <span
                        :for={d <- deliveries}
                        class={[
                          "badge badge-xs",
                          elem(status_badge(d.status), 0)
                        ]}
                        title={d.error || d.chat_id}
                      >
                        {d.label || d.chat_id}
                      </span>
                    </div>
                  <% end %>
                </:col>
                <:col :let={n} label={gettext("Status")}>
                  <% {cls, text} = status_badge(n.status) %>
                  <div class="flex items-center gap-1.5">
                    <span class={"badge badge-sm " <> cls}>{text}</span>
                    <button
                      :if={n.error}
                      type="button"
                      phx-click="show_error"
                      phx-value-id={n.id}
                      id={"notification-error-btn-" <> n.id}
                      class="btn btn-ghost btn-xs text-error"
                      title={gettext("View error details")}
                    >
                      <.icon name="hero-exclamation-circle" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </:col>
                <:action :let={n}>
                  <button
                    type="button"
                    phx-click="resend"
                    phx-value-id={n.id}
                    class="btn btn-ghost btn-xs"
                    id={"resend-" <> n.id}
                  >
                    <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Resend")}
                  </button>
                </:action>
                <:empty>
                  <.icon name="hero-bell-slash" class="w-8 h-8 mx-auto mb-2 opacity-40" />
                  <p class="text-sm">{gettext("No notifications emitted yet.")}</p>
                </:empty>
              </.table>
            </div>

            <.admin_pagination
              id="notifications-pagination"
              page={@page}
              per_page={@per_page}
              total={@total_notifications}
              total_pages={@total_pages}
            />
          </div>
        </.section>
      </div>

      <.modal
        :if={@error_detail}
        id="notification-error-modal"
        title={gettext("Delivery error details")}
        on_close="close_error"
        max_w="max-w-lg"
      >
        <div class="space-y-3 text-sm">
          <div class="flex items-center justify-between text-xs text-base-content/60">
            <span class="font-medium text-base-content">
              {event_label(@error_detail.notification.event)}
            </span>
            <span>{format_datetime_short(@error_detail.notification.inserted_at, @timezone)}</span>
          </div>

          <pre
            id="notification-error-message"
            class="text-xs bg-base-200/60 rounded-lg p-3 whitespace-pre-wrap break-words font-mono text-error"
          >{@error_detail.notification.error}</pre>

          <div :if={@error_detail.deliveries != []} class="space-y-1.5">
            <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              {gettext("Per-chat attempts")}
            </p>
            <div
              :for={d <- @error_detail.deliveries}
              class="flex items-start justify-between gap-3 rounded-lg border border-base-300 p-2 text-xs"
            >
              <div class="min-w-0">
                <div class="font-medium truncate">{d.label || d.chat_id}</div>
                <div class="font-mono text-base-content/50">{d.chat_id}</div>
                <div :if={d.error} class="text-error mt-0.5 break-all">{d.error}</div>
              </div>
              <span class={["badge badge-xs shrink-0", elem(status_badge(d.status), 0)]}>
                {elem(status_badge(d.status), 1)}
              </span>
            </div>
          </div>
        </div>
        <:footer>
          <button type="button" phx-click="close_error" class="btn btn-ghost btn-sm">
            {gettext("Close")}
          </button>
        </:footer>
      </.modal>
    </Layouts.dashboard>
    """
  end
end
