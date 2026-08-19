defmodule TokengateWeb.PromptInspectorLive do
  @moduledoc false
  use TokengateWeb, :live_view

  alias Tokengate.Prompts.Cache

  @pubsub Tokengate.PubSub
  @topic Cache.topic()

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
      |> require_admin_hook()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)

      entries = Cache.list()

      socket =
        socket
        |> stream(:prompts, entries)

      {:ok, socket}
    else
      {:ok, stream(socket, :prompts, Cache.list())}
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
  def handle_info({:prompt_captured, entry}, socket) do
    if entry_matches_filters?(entry, socket.assigns[:filters]) do
      {:noreply, stream_insert(socket, :prompts, entry, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("apply_filter", %{"filter" => filter_params}, socket) do
    filters =
      Map.merge(default_filters(), fn _k, _v1, v2 -> v2 end, filter_params)

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
    entry = Enum.find(socket.assigns.prompts |> Map.values(), &(&1.id == id))
    {:noreply, assign(socket, :modal_prompt, entry)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal_prompt, nil)}
  end

  ## Filtering -------------------------------------------------------------

  defp default_filters do
    %{
      "user_email" => "",
      "subject_type" => "",
      "model" => "",
      "agent_type" => ""
    }
  end

  defp entry_matches_filters?(entry, filters) do
    email_match?(entry.user_email, filters["user_email"]) and
      subject_type_match?(entry.subject_type, filters["subject_type"]) and
      model_match?(entry.model_requested, filters["model"]) and
      agent_type_match?(entry.agent_type, filters["agent_type"])
  end

  defp email_match?(_email, ""), do: true
  defp email_match?(nil, _), do: true
  defp email_match?(email, search), do: String.contains?(email, search)

  defp subject_type_match?(_type, ""), do: true
  defp subject_type_match?(type, type), do: true
  defp subject_type_match?(_, _), do: false

  defp agent_type_match?(_type, ""), do: true
  defp agent_type_match?(nil, _), do: true
  defp agent_type_match?(type, search), do: String.contains?(type, search)

  defp model_match?(_model, ""), do: true
  defp model_match?(nil, _), do: true
  defp model_match?(model, search), do: String.contains?(model, search)

  defp reset_stream_with_filters(socket) do
    all_entries = Cache.list()
    filtered = Enum.filter(all_entries, &entry_matches_filters?(&1, socket.assigns.filters))
    stream(socket, :prompts, filtered, reset: true)
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">Prompt Inspector</h1>
          <p class="mt-1 text-sm text-gray-500">Real-time prompt capture from the proxy hot path</p>
        </div>
      </div>

      <%!-- Filters --%>
      <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-4 mb-6">
        <.form for={@form} phx-submit="apply_filter" class="flex flex-wrap gap-4 items-end">
          <div>
            <label class="block text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">Email</label>
            <.input
              field={@form[:user_email]}
              type="text"
              placeholder="user@example.com"
              phx-debounce="300"
              class="w-48 text-sm"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">Subject</label>
            <.input
              field={@form[:subject_type]}
              type="select"
              prompt="All"
              options={[{"User", "user"}, {"Service", "service"}]}
              class="w-32 text-sm"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">Model</label>
            <.input
              field={@form[:model]}
              type="text"
              placeholder="gpt-4o"
              phx-debounce="300"
              class="w-40 text-sm"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">Agent</label>
            <.input
              field={@form[:agent_type]}
              type="text"
              placeholder="api"
              phx-debounce="300"
              class="w-32 text-sm"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="inline-flex items-center px-3 py-2 text-sm font-medium text-white bg-indigo-600 rounded-lg hover:bg-indigo-500"
            >
              <.icon name="hero-magnifying-glass" class="w-4 h-4" />
            </button>
            <button
              type="button"
              phx-click="clear_filters"
              class="inline-flex items-center px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200"
            >
              Clear
            </button>
          </div>
        </.form>
      </div>

      <%!-- Table --%>
      <div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                Time
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                User
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                Subject
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                Model
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                Agent
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wide">
                Prompt
              </th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody id="prompts-table" phx-update="stream" class="bg-white divide-y divide-gray-100">
            <tr
              :for={{dom_id, entry} <- @streams.prompts}
              id={dom_id}
              class="hover:bg-gray-50 cursor-pointer"
              phx-click="show_prompt"
              phx-value-id={entry.id}
            >
              <td class="px-4 py-3 text-sm text-gray-500 whitespace-nowrap">
                {Calendar.strftime(entry.started_at, "%Y-%m-%d %H:%M:%S")}
              </td>
              <td class="px-4 py-3 text-sm text-gray-900">
                {entry.user_email || "—"}
              </td>
              <td class="px-4 py-3">
                <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{if entry.subject_type == "service", do: "bg-purple-100 text-purple-800", else: "bg-blue-100 text-blue-800"}"}>
                  {entry.subject_type || "—"}
                </span>
              </td>
              <td class="px-4 py-3 text-sm text-gray-900 font-mono">
                {entry.model_requested || "—"}
              </td>
              <td class="px-4 py-3 text-sm text-gray-500">
                {entry.agent_type || "—"}
              </td>
              <td class="px-4 py-3 text-sm text-gray-500 max-w-xs truncate">
                {entry.preview}
              </td>
              <td class="px-4 py-3 text-right">
                <.icon name="hero-chevron-right" class="w-4 h-4 text-gray-400" />
              </td>
            </tr>
          </tbody>
        </table>

        <div
          :if={@streams.prompts |> Map.values() |> length() == 0}
          class="px-4 py-12 text-center text-sm text-gray-500"
        >
          No prompts captured yet.
        </div>
      </div>
    </div>

    <%!-- Modal --%>
    <div
      :if={@modal_prompt}
      class="fixed inset-0 z-50 overflow-y-auto"
      aria-labelledby="modal-title"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex min-h-full items-end justify-center px-4 pt-4 pb-20 text-center sm:block sm:p-0">
        <div
          class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity"
          aria-hidden="true"
          phx-click="close_modal"
        >
        </div>
        <div
          class="inline-block transform overflow-hidden rounded-lg bg-white text-left align-bottom shadow-xl transition-all sm:my-8 sm:w-full sm:max-w-3xl"
          onclick="event.stopPropagation()"
        >
          <div class="bg-white px-4 pt-5 pb-4 sm:p-6 sm:pb-4">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-gray-900" id="modal-title">Full Prompt</h3>
              <button type="button" phx-click="close_modal" class="text-gray-400 hover:text-gray-500">
                <.icon name="hero-x-mark" class="w-6 h-6" />
              </button>
            </div>
            <div class="mb-3 text-sm text-gray-500">
              <span class="font-medium">Model:</span> {@modal_prompt.model_requested} ·
              <span class="font-medium">User:</span> {@modal_prompt.user_email || "—"} ·
              <span class="font-medium">Time:</span> {Calendar.strftime(
                @modal_prompt.started_at,
                "%Y-%m-%d %H:%M:%S"
              )}
            </div>
            <div class="bg-gray-50 rounded-lg p-4 overflow-auto max-h-[60vh]">
              <pre class="text-sm text-gray-800 whitespace-pre-wrap break-words font-mono"><%= Jason.encode!(@modal_prompt.messages, pretty: true) %></pre>
            </div>
          </div>
          <div class="bg-gray-50 px-4 py-3 sm:flex sm:flex-row-reverse sm:px-6">
            <a
              href="/dashboard/logs"
              class="inline-flex items-center px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-lg hover:bg-indigo-500"
            >
              <.icon name="hero-document-text" class="w-4 h-4 mr-1" /> View in Logs
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
