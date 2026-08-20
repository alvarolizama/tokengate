defmodule TokengateWeb.PromptInspectorLive do
  @moduledoc false
  use TokengateWeb, :live_view

  alias Tokengate.Prompts.Cache
  alias Tokengate.Providers

  @pubsub Tokengate.PubSub
  @topic Cache.topic()
  @max_rows 200

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Prompt Inspector · Tokengate")
      |> assign(:is_admin, user.global_role == "admin")
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> assign(:modal_prompt, nil)
      |> assign(:model_options, model_options())
      |> require_admin_hook()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)

      entries = Cache.list_recent(@max_rows)

      socket =
        socket
        |> stream(:prompts, entries, limit: @max_rows)

      {:ok, socket}
    else
      {:ok, stream(socket, :prompts, Cache.list_recent(@max_rows), limit: @max_rows)}
    end
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly
  # over the WebSocket. Halt every event for non-admins.
  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:prompt_captured, row}, socket) do
    if Cache.matches_filters?(row, socket.assigns[:filters]) do
      {:noreply, stream_insert(socket, :prompts, row, at: 0, limit: @max_rows)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("apply_filter", %{"filter" => filter_params}, socket) do
    filters =
      Map.merge(default_filters(), filter_params, fn _k, _v1, v2 -> v2 end)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:form, to_form(filters, as: :filter))
      |> reset_stream_with_filters()

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> reset_stream_with_filters()

    {:noreply, socket}
  end

  def handle_event("show_prompt", %{"id" => id}, socket) do
    # Look up the entry from the cache, not from assigns — the stream lives
    # in assigns.streams.prompts (a %{dom_id => entry} map), so the flat
    # assigns list is not a reliable source for a single entry by id.
    entry = Cache.get(id)

    if entry do
      {:noreply,
       socket
       |> assign(:modal_prompt, entry)
       |> push_event("open_modal", %{id: "prompt-modal"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_prompt, nil)
     |> push_event("close_modal", %{id: "prompt-modal"})}
  end

  ## Filtering -------------------------------------------------------------

  defp default_filters do
    %{
      "user_email" => "",
      "subject_type" => "",
      "model" => ""
    }
  end

  defp reset_stream_with_filters(socket) do
    entries = Cache.list_recent(@max_rows, socket.assigns.filters)
    stream(socket, :prompts, entries, reset: true, limit: @max_rows)
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Prompt Inspector
          <:subtitle>Captura en tiempo real de los prompts que pasan por el proxy</:subtitle>
        </.header>

        <%!-- Filters --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <.form for={@form} phx-submit="apply_filter" class="flex flex-wrap gap-4 items-end">
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs">Email</span>
                </label>
                <.input
                  field={@form[:user_email]}
                  type="text"
                  placeholder="user@example.com"
                  phx-debounce="300"
                  class="input input-bordered input-sm w-48"
                />
              </div>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs">Subject</span>
                </label>
                <.input
                  field={@form[:subject_type]}
                  type="select"
                  prompt="All"
                  options={[{"User", "user"}, {"Service", "service"}]}
                  class="select select-bordered select-sm w-32"
                />
              </div>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs">Model</span>
                </label>
                <.input
                  field={@form[:model]}
                  type="select"
                  prompt="All"
                  options={@model_options}
                  class="select select-bordered select-sm w-40"
                />
              </div>
              <div class="form-control">
                <div class="flex gap-2 mb-2">
                  <button type="submit" class="btn btn-primary btn-sm">
                    <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Filtrar
                  </button>
                  <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm">
                    Limpiar
                  </button>
                </div>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Table --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm overflow-x-auto">
          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>User</th>
                  <th>Subject</th>
                  <th>Model</th>
                  <th>Prompt</th>
                  <th></th>
                </tr>
              </thead>
              <tbody id="prompts-table" phx-update="stream">
                <tr
                  :for={{dom_id, entry} <- @streams.prompts}
                  id={dom_id}
                  class="cursor-pointer hover:bg-base-200"
                  phx-click="show_prompt"
                  phx-value-id={entry.id}
                >
                  <td class="whitespace-nowrap text-xs">
                    {Calendar.strftime(entry.started_at, "%Y-%m-%d %H:%M:%S")}
                  </td>
                  <td>{entry.user_email || "—"}</td>
                  <td>
                    <span class={badge_class(entry.subject_type)}>
                      {entry.subject_type || "—"}
                    </span>
                  </td>
                  <td class="font-mono text-xs">{entry.model_requested || "—"}</td>
                  <td class="max-w-xs truncate text-xs text-base-content/70">
                    {entry.last_preview || ""}
                  </td>
                  <td class="text-right">
                    <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/40" />
                  </td>
                </tr>
              </tbody>
            </table>

            <div
              :if={@streams.prompts |> Map.values() |> length() == 0}
              class="p-8 text-center text-sm text-base-content/50"
            >
              No prompts capturados todavía.
            </div>
          </div>
        </div>
      </div>

      <%!-- Full prompt modal --%>
      <dialog
        id="prompt-modal"
        class="modal"
        phx-hook="Modal"
        data-open={if(@modal_prompt != nil, do: "true", else: "false")}
      >
        <div class="modal-box max-w-3xl">
          <h3 class="text-lg font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-command-line" class="w-5 h-5" /> Prompt completo
          </h3>
          <div
            :if={@modal_prompt}
            class="py-4 text-sm text-base-content/70 space-y-2"
          >
            <p>
              <span class="font-semibold text-base-content">Model:</span>
              {@modal_prompt.model_requested || "—"}
            </p>
            <p>
              <span class="font-semibold text-base-content">User:</span>
              {@modal_prompt.user_email || "—"}
            </p>
            <p>
              <span class="font-semibold text-base-content">Time:</span>
              {Calendar.strftime(@modal_prompt.started_at, "%Y-%m-%d %H:%M:%S")}
            </p>
            <p>
              <span class="font-semibold text-base-content">Messages:</span>
              {length(@modal_prompt.messages)}
            </p>
            <p>
              <span class="font-semibold text-base-content">Size:</span>
              {format_prompt_size(@modal_prompt.messages)}
            </p>
            <p>
              <span class="font-semibold text-base-content">Agent:</span>
              {@modal_prompt.agent_type || "—"}
            </p>
            <p>
              <span class="font-semibold text-base-content">Subject:</span>
              <span class={badge_class(@modal_prompt.subject_type)}>
                {@modal_prompt.subject_type || "—"}
              </span>
            </p>
            <p>
              <span class="font-semibold text-base-content">Client:</span>
              {@modal_prompt.client_agent || "—"}
            </p>
          </div>
          <div :if={@modal_prompt} class="bg-base-200 rounded-lg p-4 overflow-auto max-h-[55vh]">
            <pre class="text-xs text-base-content whitespace-pre-wrap break-words font-mono"><%= Jason.encode!(@modal_prompt.messages, pretty: true) %></pre>
          </div>
          <div class="modal-action">
            <form method="dialog">
              <button class="btn btn-ghost btn-sm" phx-click="close_modal">Cerrar</button>
            </form>
            <a href="/dashboard/logs" class="btn btn-primary btn-sm">
              <.icon name="hero-document-text" class="w-4 h-4" /> Ver en Logs
            </a>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop" phx-click="close_modal">
          <button>close</button>
        </form>
      </dialog>
    </Layouts.dashboard>
    """
  end

  defp badge_class("service"), do: "badge badge-sm badge-accent"
  defp badge_class("user"), do: "badge badge-sm badge-info"
  defp badge_class(_), do: "badge badge-sm"

  defp model_options do
    Providers.list_model_aliases()
    |> Enum.map(fn alias_ -> {alias_.name, alias_.name} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp format_prompt_size(messages) do
    size = messages |> Jason.encode!() |> byte_size()
    kb = Float.round(size / 1024, 1)
    "#{kb} KB"
  end
end
