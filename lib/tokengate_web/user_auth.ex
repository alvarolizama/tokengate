defmodule TokengateWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` hooks for browser session authentication.

  These are the LiveView analogues of `TokengateWeb.Plugs.DashboardAuth`.
  They read the `:user_id` from the LiveView session (set by the endpoint
  socket connect_info) and assign `:current_user` on the socket.

  Hooks:

    * `:default`              — assigns `current_user` when present, `nil` otherwise.
    * `:require_authenticated` — redirects to `/login` when no current_user.
    * `:require_admin`         — redirects non-admins (or unauthenticated visitors)
      to `/login` or `/dashboard` respectively.
    * `:require_service_supervisor` — the supervised-services area: requires a live
      `service_supervisors` row (not a role). Non-supervisors go to `/dashboard`.

  All three also assign `:current_path` (the request path, refreshed on every
  navigation) so the sidebar can highlight the active link.

  Usage in the router:

      live_session :dashboard, on_mount: [{TokengateWeb.UserAuth, :require_authenticated}] do
        live "/dashboard", DashboardLive
      end

      live_session :admin, on_mount: [{TokengateWeb.UserAuth, :require_admin}] do
        # admin-only LiveViews
      end
  """

  import Phoenix.Component, only: [assign_new: 3]
  alias Tokengate.Accounts
  alias TokengateWeb.Gettext

  @session_key :user_id

  @doc """
  Assigns `current_user` from the session and gates by mode:

    * `:default` — assigns when present, never redirects.
    * `:require_authenticated` — redirects to `/login` when absent.
    * `:require_admin` — unauthenticated → `/login`, non-admins → `/dashboard`.
  """
  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn -> fetch_user(session) end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> attach_path_handler()

    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> assign_timezone(user)
      |> attach_timezone_handler()
      |> assign_locale(user)
      |> attach_locale_handler()
      |> attach_path_handler()

    if user do
      track_presence(socket, user)
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> assign_timezone(user)
      |> attach_timezone_handler()
      |> assign_locale(user)
      |> attach_locale_handler()
      |> attach_path_handler()

    case user do
      %{global_role: "admin"} ->
        track_presence(socket, user)
        {:cont, socket}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      _non_admin ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/dashboard")}
    end
  end

  # Gates the supervised-services area: access is granted **only** by a live
  # `service_supervisors` row, never by the user's global role.
  #
  # Unauthenticated visitors go to `/login`; a signed-in user who does not
  # supervise any service goes to `/dashboard` with an error flash. Because the
  # check hits the database on every mount (including socket reconnects, where
  # plugs don't run again), removing a user as supervisor revokes the access.
  def on_mount(:require_service_supervisor, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> assign_timezone(user)
      |> attach_timezone_handler()
      |> assign_locale(user)
      |> attach_locale_handler()
      |> attach_path_handler()

    case user do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      %{id: user_id} = user ->
        if Accounts.count_services_for_supervisor(user_id) > 0 do
          track_presence(socket, user)
          {:cont, socket}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(
             :error,
             "Solo los supervisores de servicios pueden acceder a esta sección."
           )
           |> Phoenix.LiveView.redirect(to: "/dashboard")}
        end
    end
  end

  # Assigns the user's timezone on the socket for use in date formatting.
  defp assign_timezone(socket, %{timezone: tz}) when is_binary(tz),
    do: Phoenix.Component.assign(socket, :timezone, tz)

  defp assign_timezone(socket, _), do: Phoenix.Component.assign(socket, :timezone, "Etc/UTC")

  # Attaches a live_hook that handles the "set-timezone" event from the
  # sidebar selector. Persists the timezone to the user's record and
  # updates the socket assign so all date formatters pick it up.
  defp attach_timezone_handler(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :timezone_handler,
      :handle_event,
      &handle_timezone_event/3
    )
  end

  defp handle_timezone_event("set-timezone", %{"timezone" => tz}, socket) do
    user = socket.assigns[:current_user]

    if user && tz != user.timezone do
      case Accounts.update_user_timezone(user, tz) do
        {:ok, updated_user} ->
          {:halt,
           socket
           |> Phoenix.Component.assign(:timezone, tz)
           |> Phoenix.Component.assign(:current_user, updated_user)}

        {:error, _changeset} ->
          {:halt, socket}
      end
    else
      {:halt, Phoenix.Component.assign(socket, :timezone, tz)}
    end
  end

  defp handle_timezone_event(_event, _params, socket), do: {:cont, socket}

  # Idioma de la UI: mismo patrón que el timezone (assign + hook del evento),
  # porque el proceso del LiveView no comparte el locale que fijó el plug.
  # `Gettext.put_locale/2` se aplica aquí para que el propio render de este
  # evento (sidebar incluido) ya salga en el idioma nuevo.
  defp assign_locale(socket, user) do
    locale = Gettext.put_locale(Gettext.locale_of(user))
    Phoenix.Component.assign(socket, :locale, locale)
  end

  defp attach_locale_handler(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :locale_handler,
      :handle_event,
      &handle_locale_event/3
    )
  end

  defp handle_locale_event("set-locale", %{"locale" => locale}, socket) do
    locale = Gettext.put_locale(locale)
    user = socket.assigns[:current_user]

    if user && locale != user.locale do
      case Accounts.update_user_locale(user, locale) do
        {:ok, updated_user} ->
          {:halt,
           socket
           |> Phoenix.Component.assign(:locale, locale)
           |> Phoenix.Component.assign(:current_user, updated_user)
           |> reload_locale()}

        {:error, _changeset} ->
          {:halt, Phoenix.Component.assign(socket, :locale, locale)}
      end
    else
      {:halt, socket |> Phoenix.Component.assign(:locale, locale) |> reload_locale()}
    end
  end

  defp handle_locale_event(_event, _params, socket), do: {:cont, socket}

  # El idioma decide **todo** el texto de la página, y el diff de LiveView no
  # vuelve a enviar el texto ya renderizado de los componentes: se remonta el
  # LiveView en su misma ruta para que todo se pinte en el idioma nuevo (es un
  # navigate, no una recarga HTTP).
  defp reload_locale(socket) do
    case socket.assigns[:current_path] do
      path when is_binary(path) -> Phoenix.LiveView.push_navigate(socket, to: path)
      _ -> socket
    end
  end

  # Tracks the URL the user is currently on in the `:current_path` assign.
  # `handle_params` is the only LiveView callback that receives the URI, and
  # it runs both on the static render and on every live_patch / navigate, so
  # the sidebar highlight stays in sync without any per-LiveView plumbing.
  defp attach_path_handler(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :current_path_handler,
      :handle_params,
      fn _params, uri, socket ->
        path = uri |> URI.parse() |> Map.get(:path)
        {:cont, Phoenix.Component.assign(socket, :current_path, path)}
      end
    )
  end

  # Track the connected LiveView in Phoenix.Presence so the topbar can show
  # how many users are on the dashboard right now. Only the connected mount
  # owns a real websocket process worth tracking.
  defp track_presence(socket, user) do
    if Phoenix.LiveView.connected?(socket) do
      {:ok, _} = TokengateWeb.Presence.track_user(self(), user)
    end

    :ok
  end

  defp fetch_user(session) do
    # LiveView sessions use string keys; plug sessions may use atoms.
    case session["user_id"] || session[@session_key] do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end

  # The original admin while an impersonation session is active. Stored in
  # the session by SessionController.impersonate/2; `nil` otherwise.
  defp fetch_impersonator(session) do
    case session["impersonator_id"] || session[:impersonator_id] do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end
end
