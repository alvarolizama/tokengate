defmodule TokengateWeb.RoutingRulesLive do
  @moduledoc """
  Admin CRUD for organization-scoped routing rules.

  Each rule maps request conditions to a target model alias. Conditions
  are edited through predefined fields (no raw JSON):

    - context_length: minimum context tokens ("> N")
    - has_images: request contains images (true/false)
    - agent_type: exact agent type match (e.g. "claude-code")

  Rules are evaluated by priority ASC — lower number wins.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.RoutingRule

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Routing Rules · Tokengate")
      |> assign(:form, nil)
      |> assign(:conditions_form, empty_conditions())
      |> assign(:editing_rule_id, nil)
      |> load_rules()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_rules(socket) do
    rules =
      Providers.list_routing_rules()
      |> Tokengate.Repo.preload([:organization, :target_alias])
      |> Enum.sort_by(fn r -> {r.organization.name, r.priority} end)

    socket
    |> assign(:rules, rules)
    |> assign(:rules_empty?, rules == [])
    |> assign(:organizations, Accounts.list_organizations())
    |> assign(:model_aliases, Providers.list_model_aliases())
  end

  ## Events — form ---------------------------------------------------------

  @impl true
  def handle_event("new_rule", _params, socket) do
    changeset = Providers.change_routing_rule(%RoutingRule{enabled: true, priority: 1})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :rule))
     |> assign(:conditions_form, empty_conditions())
     |> assign(:editing_rule_id, :new)}
  end

  def handle_event("edit_rule", %{"id" => rule_id}, socket) do
    rule = Providers.get_routing_rule!(rule_id)
    changeset = Providers.change_routing_rule(rule)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :rule))
     |> assign(:conditions_form, conditions_to_form(rule.conditions))
     |> assign(:editing_rule_id, rule.id)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_rule_id, nil)}
  end

  def handle_event("save_rule", %{"rule" => rule_params} = params, socket) do
    conditions = build_conditions(params)
    rule_params = Map.put(rule_params, "conditions", conditions)

    save_rule(socket, socket.assigns.editing_rule_id, rule_params)
  end

  def handle_event("toggle_enabled", %{"id" => rule_id}, socket) do
    rule = Providers.get_routing_rule!(rule_id)

    case Providers.update_routing_rule(rule, %{enabled: !rule.enabled}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Regla actualizada.")
         |> load_rules()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar la regla.")}
    end
  end

  def handle_event("delete_rule", %{"id" => rule_id}, socket) do
    rule = Providers.get_routing_rule!(rule_id)

    case Providers.delete_routing_rule(rule) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Regla eliminada.")
         |> load_rules()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la regla.")}
    end
  end

  ## Private helpers --------------------------------------------------------

  defp save_rule(socket, :new, rule_params) do
    case Providers.create_routing_rule(rule_params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Regla creada correctamente.")
         |> assign(:form, nil)
         |> assign(:editing_rule_id, nil)
         |> load_rules()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :rule))}
    end
  end

  defp save_rule(socket, rule_id, rule_params) do
    rule = Providers.get_routing_rule!(rule_id)

    case Providers.update_routing_rule(rule, rule_params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Regla actualizada correctamente.")
         |> assign(:form, nil)
         |> assign(:editing_rule_id, nil)
         |> load_rules()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :rule))}
    end
  end

  defp empty_conditions do
    %{"context_length_min" => "", "has_images" => "", "agent_type" => ""}
  end

  defp conditions_to_form(conditions) when is_map(conditions) do
    context_min =
      case Map.get(conditions, "context_length") do
        ">" <> rest -> rest
        _ -> ""
      end

    has_images =
      case Map.get(conditions, "has_images") do
        true -> "true"
        false -> "false"
        _ -> ""
      end

    %{
      "context_length_min" => context_min,
      "has_images" => has_images,
      "agent_type" => Map.get(conditions, "agent_type", "") || ""
    }
  end

  defp build_conditions(params) do
    cond_form = Map.get(params, "conditions", %{})

    %{}
    |> maybe_put_condition(
      "context_length",
      context_length_value(cond_form["context_length_min"])
    )
    |> maybe_put_condition("has_images", has_images_value(cond_form["has_images"]))
    |> maybe_put_condition("agent_type", blank_to_nil(cond_form["agent_type"]))
  end

  defp context_length_value(nil), do: nil
  defp context_length_value(""), do: nil
  defp context_length_value(n), do: "> #{n}"

  defp has_images_value("true"), do: true
  defp has_images_value("false"), do: false
  defp has_images_value(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp maybe_put_condition(map, _key, nil), do: map
  defp maybe_put_condition(map, key, value), do: Map.put(map, key, value)

  ## Template helpers --------------------------------------------------------

  defp conditions_badges(conditions) when conditions == %{}, do: []

  defp conditions_badges(conditions) do
    []
    |> maybe_badge("context_length", conditions, fn v -> "contexto #{v}" end)
    |> maybe_badge("has_images", conditions, fn
      true -> "con imágenes"
      false -> "sin imágenes"
      _ -> nil
    end)
    |> maybe_badge("agent_type", conditions, fn v -> "agente: #{v}" end)
  end

  defp maybe_badge(badges, key, conditions, fun) do
    case Map.get(conditions, key) do
      nil ->
        badges

      value ->
        case fun.(value) do
          nil -> badges
          label -> badges ++ [label]
        end
    end
  end

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Routing Rules
          <:subtitle>Reglas de ruteo entre model aliases por condiciones del request</:subtitle>
        </.header>

        <div class="flex justify-end">
          <button phx-click="new_rule" class="btn btn-primary btn-sm" id="new-rule-btn">
            <.icon name="hero-plus" class="w-4 h-4" /> Nueva regla
          </button>
        </div>

        <%!-- Form (create / edit) --%>
        <div :if={@form} class="card bg-base-100 border border-base-300 shadow-sm" id="rule-form-card">
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">
              {if @editing_rule_id == :new, do: "Nueva regla", else: "Editar regla"}
            </h2>
            <.form for={@form} id="rule-form" phx-submit="save_rule">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  field={@form[:organization_id]}
                  type="select"
                  label="Organización"
                  prompt="Selecciona organización"
                  options={Enum.map(@organizations, fn o -> {o.name, o.id} end)}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre"
                  placeholder="long-context-to-anthropic"
                />
                <.input
                  field={@form[:target_alias_id]}
                  type="select"
                  label="Alias destino"
                  prompt="Selecciona alias"
                  options={Enum.map(@model_aliases, fn a -> {a.name, a.id} end)}
                />
                <.input field={@form[:priority]} type="number" label="Prioridad (menor = primero)" />
              </div>

              <h3 class="text-sm font-semibold mt-4 mb-2">Condiciones (opcionales)</h3>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <.input
                  field={@form[:context_length_min]}
                  type="number"
                  name="conditions[context_length_min]"
                  label="Contexto mínimo (tokens)"
                  value={@conditions_form["context_length_min"]}
                  placeholder="100000"
                />
                <.input
                  field={@form[:has_images]}
                  type="select"
                  name="conditions[has_images]"
                  label="Imágenes"
                  prompt="Cualquiera"
                  options={[{"Sí", "true"}, {"No", "false"}]}
                  value={@conditions_form["has_images"]}
                />
                <.input
                  field={@form[:agent_type]}
                  type="text"
                  name="conditions[agent_type]"
                  label="Agent type"
                  value={@conditions_form["agent_type"]}
                  placeholder="claude-code"
                />
              </div>

              <.input field={@form[:enabled]} type="checkbox" label="Habilitada" />

              <div class="flex gap-2 mt-4">
                <button type="submit" class="btn btn-primary btn-sm" id="save-rule-btn">Guardar</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Rules list --%>
        <div :if={@rules_empty?} class="text-center py-12 text-base-content/40" id="rules-empty">
          <.icon name="hero-arrows-right-left" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>No hay reglas de ruteo todavía.</p>
        </div>

        <div class="space-y-3" id="rules">
          <div
            :for={rule <- @rules}
            id={"rule-#{rule.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="font-semibold text-base-content">{rule.name}</h3>
                    <span class={[
                      "badge badge-sm",
                      if(rule.enabled, do: "badge-success", else: "badge-ghost")
                    ]}>
                      {if rule.enabled, do: "Activa", else: "Deshabilitada"}
                    </span>
                  </div>
                  <p class="text-xs text-base-content/50 mt-1">
                    {rule.organization.name} · prioridad {rule.priority} →
                    <span class="font-mono">{rule.target_alias.name}</span>
                  </p>
                  <div class="flex flex-wrap gap-2 mt-2">
                    <span
                      :for={label <- conditions_badges(rule.conditions)}
                      class="badge badge-sm badge-outline"
                    >
                      {label}
                    </span>
                    <span :if={rule.conditions == %{}} class="text-xs text-base-content/40">
                      Sin condiciones — aplica a todo
                    </span>
                  </div>
                </div>
                <div class="flex gap-2">
                  <button
                    phx-click="toggle_enabled"
                    phx-value-id={rule.id}
                    class="btn btn-sm btn-ghost"
                    id={"toggle-#{rule.id}"}
                  >
                    {if rule.enabled, do: "Deshabilitar", else: "Habilitar"}
                  </button>
                  <button
                    phx-click="edit_rule"
                    phx-value-id={rule.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{rule.id}"}
                  >
                    <.icon name="hero-pencil-square" class="w-4 h-4" /> Editar
                  </button>
                  <button
                    phx-click="delete_rule"
                    phx-value-id={rule.id}
                    data-confirm="¿Eliminar esta regla de ruteo?"
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{rule.id}"}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> Eliminar
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
