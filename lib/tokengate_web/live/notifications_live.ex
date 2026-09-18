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

  # How many recent deliveries the log shows (newest first). Bounded so the
  # page stays cheap; the full trail lives in the audit/DB.
  @delivery_log_limit 50

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Telegram
  alias Tokengate.Notifications.TelegramWorker

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
        |> assign(:delivery_log_limit, @delivery_log_limit)
        |> assign(:link_form, link_form())
        |> assign(:quiet_form, quiet_form())
        |> load_data()

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

    socket
    |> assign(:settings, settings)
    |> assign(:events, Notifications.effective_events())
    |> assign(:env_token?, is_binary(Application.get_env(:tokengate, :telegram_bot_token)))
    |> assign(:token_set?, not is_nil(settings.bot_token))
    |> assign(:configured?, Telegram.configured?())
    |> assign(:links_empty?, Notifications.list_links() == [])
    |> stream(:links, Notifications.list_links(), reset: true)
    |> load_notifications()
  end

  defp load_notifications(socket) do
    notifications = Notifications.list_notifications(%{limit: @delivery_log_limit})

    socket
    |> assign(:notifications_empty?, notifications == [])
    |> stream(:notifications, notifications, reset: true)
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("save_token", %{"token" => %{"bot_token" => token}}, socket) do
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
            Enum.map(
              targets,
              &{&1, Telegram.send_message(&1.chat_id, message(:test), thread_opts(&1))}
            )

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
    Notifications.delete_link(id)
    audit(socket, "notification.link_remove", "telegram_link", id, %{})

    {:noreply,
     socket
     |> put_flash(:info, gettext("Chat removed."))
     |> load_data()}
  end

  def handle_event("resend", %{"id" => id}, socket) do
    notification = Notifications.get_notification!(id)

    notification
    |> Ecto.Changeset.change(%{status: "pending", error: nil})
    |> Tokengate.Repo.update()

    %{notification_id: notification.id}
    |> TelegramWorker.new()
    |> Oban.insert()

    audit(socket, "notification.resend", "notification", notification.id, %{
      "event" => notification.event
    })

    {:noreply,
     socket
     |> put_flash(:info, gettext("Resend queued."))
     |> load_notifications()}
  end

  def handle_event("refresh_log", _params, socket) do
    {:noreply, load_notifications(socket)}
  end

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
        <div class="card bg-base-100 border border-base-300" id="notifications-bot-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-paper-airplane" class="w-5 h-5" /> {gettext("Bot")}
            </h2>

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
                  class="btn btn-ghost btn-sm text-error"
                  id="clear-token-btn"
                >
                  {gettext("Remove stored token")}
                </button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Events --%>
        <div class="card bg-base-100 border border-base-300" id="notifications-events-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-list-bullet" class="w-5 h-5" /> {gettext("Events")}
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Choose which events are delivered to Telegram. Each has its own anti-repeat window."
              )}
            </p>

            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Event")}</th>
                    <th>{gettext("Severity")}</th>
                    <th class="text-right">{gettext("Enabled")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @events} id={"event-row-" <> event.name}>
                    <td>
                      <div class="font-medium text-sm">{event_label(event.name)}</div>
                      <div
                        :if={event_description(event.name) != ""}
                        class="text-xs text-base-content/50"
                      >
                        {event_description(event.name)}
                      </div>
                    </td>
                    <td>
                      <% {cls, text} = severity_badge(event.severity) %>
                      <span class={"badge badge-sm " <> cls}>{text}</span>
                    </td>
                    <td class="text-right">
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
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <%!-- Quiet hours --%>
        <div class="card bg-base-100 border border-base-300" id="notifications-quiet-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-moon" class="w-5 h-5" /> {gettext("Quiet hours")}
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Within this UTC window only critical events are delivered. Leave both empty to disable."
              )}
            </p>

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
              <button type="submit" class="btn btn-primary btn-sm" id="save-quiet-btn">
                {gettext("Save")}
              </button>
            </.form>
          </div>
        </div>

        <%!-- Linked chats --%>
        <div class="card bg-base-100 border border-base-300" id="notifications-links-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-user-group" class="w-5 h-5" /> {gettext("Linked chats")}
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Chats and channels that receive the notifications. The chat id is the number Telegram shows for the conversation."
              )}
            </p>

            <.form
              for={@link_form}
              id="link-form"
              phx-submit="add_link"
              class="grid grid-cols-[14%_22%_18%_34%_12%] gap-3 items-end mt-2"
            >
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
              <.input
                field={@link_form[:chat_id]}
                type="text"
                label={gettext("Chat id")}
                class="w-full input input-sm"
              />
              <.input
                field={@link_form[:thread_id]}
                type="text"
                label={gettext("Topic id")}
                class="w-full input input-sm"
              />
              <.input
                field={@link_form[:label]}
                type="text"
                label={gettext("Label")}
                class="w-full input input-sm"
              />
              <button type="submit" class="btn btn-primary btn-sm w-full mb-2" id="add-link-btn">
                {gettext("Link")}
              </button>
            </.form>

            <p class="text-xs text-base-content/50 mt-1">
              {gettext(
                "For a channel, add the bot as an administrator; a negative chat id (-100…) is normal. The topic id is only needed for a channel/group with topics."
              )}
            </p>

            <div class="mt-3">
              <table class="table table-sm table-fixed w-full">
                <colgroup>
                  <col style="width: 14%" />
                  <col style="width: 22%" />
                  <col style="width: 18%" />
                  <col style="width: 34%" />
                  <col style="width: 12%" />
                </colgroup>
                <thead>
                  <tr>
                    <th>{gettext("Kind")}</th>
                    <th>{gettext("Chat id")}</th>
                    <th>{gettext("Topic id")}</th>
                    <th>{gettext("Label")}</th>
                    <th class="text-right">{gettext("Actions")}</th>
                  </tr>
                </thead>
                <tbody id="links" phx-update="stream">
                  <tr :for={{dom_id, link} <- @streams.links} id={dom_id}>
                    <td>
                      <span class="badge badge-sm badge-ghost">{kind_label(link.kind)}</span>
                    </td>
                    <td class="font-mono text-xs">{link.chat_id}</td>
                    <td class="font-mono text-xs">{link.thread_id}</td>
                    <td class="text-sm">{link.label}</td>
                    <td class="text-right">
                      <button
                        type="button"
                        phx-click="remove_link"
                        phx-value-id={link.id}
                        class="btn btn-ghost btn-xs text-error"
                        id={"remove-link-" <> link.id}
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Remove")}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@links_empty?} class="text-center py-8 text-base-content/40" id="links-empty">
              <.icon name="hero-link-slash" class="w-8 h-8 mx-auto mb-2 opacity-40" />
              <p class="text-sm">{gettext("No linked chats yet.")}</p>
            </div>
          </div>
        </div>

        <%!-- Delivery log --%>
        <div class="card bg-base-100 border border-base-300" id="notifications-log-card">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title flex items-center gap-2">
                <.icon name="hero-inbox" class="w-5 h-5" /> {gettext("Delivery log")}
              </h2>
              <button
                type="button"
                phx-click="refresh_log"
                class="btn btn-ghost btn-xs"
                id="refresh-log-btn"
              >
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Refresh")}
              </button>
            </div>

            <p class="text-xs text-base-content/50">
              {gettext("Showing the latest %{count} deliveries, newest first.",
                count: @delivery_log_limit
              )}
            </p>

            <div class="overflow-x-auto mt-3">
              <table class="table table-sm table-fixed w-full">
                <colgroup>
                  <col style="width: 20%" />
                  <col style="width: 26%" />
                  <col style="width: 24%" />
                  <col style="width: 15%" />
                  <col style="width: 15%" />
                </colgroup>
                <thead>
                  <tr>
                    <th>{gettext("When")}</th>
                    <th>{gettext("Event")}</th>
                    <th>{gettext("Target")}</th>
                    <th>{gettext("Status")}</th>
                    <th class="text-right">{gettext("Actions")}</th>
                  </tr>
                </thead>
                <tbody id="notifications" phx-update="stream">
                  <tr :for={{dom_id, n} <- @streams.notifications} id={dom_id}>
                    <td class="text-xs text-base-content/60 whitespace-nowrap">
                      {fmt_dt(n.inserted_at)}
                    </td>
                    <td class="text-sm">{event_label(n.event)}</td>
                    <td class="text-xs">{n.target_label}</td>
                    <td>
                      <% {cls, text} = status_badge(n.status) %>
                      <span class={"badge badge-sm " <> cls} title={n.error}>{text}</span>
                    </td>
                    <td class="text-right">
                      <button
                        type="button"
                        phx-click="resend"
                        phx-value-id={n.id}
                        class="btn btn-ghost btn-xs"
                        id={"resend-" <> n.id}
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Resend")}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div
              :if={@notifications_empty?}
              class="text-center py-8 text-base-content/40"
              id="notifications-empty"
            >
              <.icon name="hero-bell-slash" class="w-8 h-8 mx-auto mb-2 opacity-40" />
              <p class="text-sm">{gettext("No notifications emitted yet.")}</p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp fmt_dt(_), do: ""
end
