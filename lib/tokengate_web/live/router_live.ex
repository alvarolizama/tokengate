defmodule TokengateWeb.RouterLive do
  @moduledoc """
  Admin surface of the SmartRouter (`/catalog/router`).

  Five URL-addressable tabs (`?tab=engine|rules|dry_run|live|versions`, default
  `engine`), so an operator can bookmark the dry-run or leave the live monitor
  open on a second screen:

    * `engine`  — the selected version's `router_configs` row, the use cases
      (`router_use_cases`) and, per use case, its effort-tiered destinations
      (`router_use_case_models`).
    * `rules`   — the version's prioritized deterministic layer
      (`router_rules`), with auto-search pickers for limit profiles, services
      and users.
    * `dry_run` — one payload through `Tokengate.SmartRouter.dry_run/3`: no
      upstream call, no session pin, no budget movement. On a candidate version
      the same payload is also decided by the serving Default, so the two
      catalogues are compared side by side.
    * `live`    — PubSub-driven monitor: `Inflight.topic()` for requests in
      flight, `"logs:new"` for completed routed requests and
      `"smart_router:shadow"` for the Shadow evaluations of those requests,
      with a bounded stream (`limit: 100`) and a discrepancy filter.
    * `versions` — every `router_configs` version: state, shadow sampling,
      promotion, archive/restore and clone.

  ## Versions

  `?version=<id>` selects the version being edited (`@editing_config`), and
  every use case, rule and dry-run read is scoped to it. The default selection
  is the version flagged `is_default` — the one serving live traffic. Two
  knobs are **global policy, not version content**: the `enabled` kill switch
  and `baseline_model_id` are always read from (and written to) the Default,
  so promoting a version can never flip the router on or off nor move the
  counterfactual baseline.

  Every mutation calls `Tokengate.SmartRouter.invalidate/0` (the snapshot lives
  one minute in `Tokengate.Cache`) and writes an audit entry through
  `TokengateWeb.Audit`, exactly like the rest of the admin screens.
  """
  use TokengateWeb, :live_view

  import Ecto.Query, warn: false

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{Group, Service, User}
  alias Tokengate.Logs.Inflight
  alias Tokengate.Providers
  alias Tokengate.Providers.Pricing
  alias Tokengate.Repo
  alias Tokengate.SmartRouter

  alias Tokengate.SmartRouter.{
    Analytics,
    Config,
    Presets,
    RequestAnalyzer,
    Rule,
    ShadowEvaluator,
    UseCase,
    UseCaseModel,
    Versions
  }

  alias TokengateWeb.StatsHelpers, as: Stats

  @tabs ~w(engine rules dry_run live versions)

  # Hard cap of the completed-requests stream (DOM + LiveView state).
  @stream_limit 100
  @inflight_limit 50
  @pulse_window_seconds 300
  @live_tick_ms 5_000

  # Fields of the config row that are worth an audit entry.
  @config_audit_fields ~w(enabled policy decision_timeout_ms decision_context_chars
    fast_path_max_tokens sticky_ttl_seconds lock_tool_loops charge_decision_to_subject
    decision_model_id default_model_id baseline_model_id)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Router") <> " · Tokengate")
      |> assign(:tab, "engine")
      |> assign(:default_config, nil)
      |> assign(:config, nil)
      |> assign(:editing_config, nil)
      |> assign(:versions, [])
      |> assign(:version_stats, %{})
      |> assign(:show_archived, false)
      |> assign(:nav_form, to_form(%{"version" => ""}, as: :nav))
      |> assign(:clone_open, false)
      |> assign(:clone_source_id, nil)
      |> assign(:clone_form, nil)
      |> assign(:clone_errors, [])
      |> assign(:diff_open, false)
      |> assign(:diff, nil)
      |> assign(:promote_open, false)
      |> assign(:promote_version_id, nil)
      |> assign(:expanded_uc, nil)
      |> assign(:uc_open, false)
      |> assign(:uc_editing, nil)
      |> assign(:uc_form, nil)
      |> assign(:uc_errors, [])
      |> assign(:dest_open, false)
      |> assign(:dest_editing, nil)
      |> assign(:dest_use_case_id, nil)
      |> assign(:dest_form, nil)
      |> assign(:dest_errors, [])
      |> assign(:rule_open, false)
      |> assign(:rule_editing, nil)
      |> assign(:rule_form, nil)
      |> assign(:rule_errors, [])
      |> reset_rule_pickers()
      |> assign(:dry_form, to_form(default_dry_params(), as: :dry))
      |> assign(:dry_result, nil)
      |> assign(:dry_error, nil)
      |> assign(:dry_trace, [])
      |> assign(:dry_audit, nil)
      |> assign(:dry_analysis, nil)
      |> assign(:dry_comparison, nil)
      |> assign(:inflight, [])
      |> assign(:pulse, empty_pulse())
      |> assign(:pulse_entries, [])
      |> assign(:live_filter, "all")
      |> assign(:shadows_by_log_id, %{})
      |> assign(:recent_logs, %{})
      |> assign(:recent_refs, [])
      |> assign(:shadows_hydrated, false)
      |> assign(:router_events_count, 0)
      |> stream(:router_events, [], reset: true)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
      Phoenix.PubSub.subscribe(Tokengate.PubSub, ShadowEvaluator.topic())
      send(self(), :router_live_tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "engine"

    socket =
      socket
      |> assign(:tab, tab)
      |> load_all(params["version"])

    socket =
      if tab == "live" do
        socket
        |> assign(:inflight, visible_inflight())
        |> hydrate_shadows()
        |> rebuild_live_stream()
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_config", %{"config" => params}, socket) do
    editing = socket.assigns.editing_config
    default = socket.assigns.default_config

    # The kill switch and the counterfactual baseline are GLOBAL policy: they
    # are only ever written on the serving Default. A candidate's form renders
    # them disabled, and this drop makes sure a hand-crafted payload cannot
    # move them through a candidate either.
    params =
      if editing.id == default.id do
        params
      else
        Map.drop(params, ["enabled", "baseline_model_id"])
      end

    params = blank_model_ids(params)

    case editing |> Config.changeset(params) |> Repo.update() do
      {:ok, config} ->
        SmartRouter.invalidate()

        audit(socket, "router.config_update", "router_config", config.id, %{
          "changes" => Map.take(params, @config_audit_fields)
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Router configuration saved."))
         |> load_all(config.id)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:config_form, to_form(changeset, as: :config))
         |> put_flash(:error, gettext("Could not save the router configuration."))}
    end
  end

  def handle_event("seed_presets", _params, socket) do
    # Seed the version being edited, not the serving Default: a clone can then
    # hold the same twelve keys without touching what live traffic sees.
    %{inserted: inserted, existing: existing} =
      Presets.ensure_all!(socket.assigns.editing_config.id)

    SmartRouter.invalidate()

    audit(socket, "router.use_case_seed", "router_use_case", "presets", %{
      "router_config_id" => socket.assigns.editing_config.id,
      "inserted" => inserted,
      "existing" => existing
    })

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Presets checked: %{inserted} created, %{existing} already present.",
         inserted: inserted,
         existing: existing
       )
     )
     |> load_use_cases()
     |> load_versions()}
  end

  # ---------------------------------------------------------------------------
  # Versions
  # ---------------------------------------------------------------------------

  def handle_event("select_version", params, socket) do
    case version_param(params) do
      nil -> {:noreply, socket}
      id -> patch_to(socket, socket.assigns.tab, id)
    end
  end

  def handle_event("open_clone_version", params, socket) do
    source_id = params["id"] || socket.assigns.editing_config.id

    source =
      Enum.find(socket.assigns.versions, &(&1.id == source_id)) || socket.assigns.editing_config

    {:noreply,
     socket
     |> assign(:clone_open, true)
     |> assign(:clone_source_id, source.id)
     |> assign(:clone_errors, [])
     |> assign(
       :clone_form,
       to_form(
         %{
           "name" => gettext("%{name} (copy)", name: source.name),
           "description" => source.description || ""
         },
         as: :clone
       )
     )}
  end

  def handle_event("cancel_clone_version", _params, socket) do
    {:noreply,
     socket
     |> assign(:clone_open, false)
     |> assign(:clone_source_id, nil)
     |> assign(:clone_form, nil)
     |> assign(:clone_errors, [])}
  end

  def handle_event("clone_version", %{"clone" => params}, socket) do
    source_id = socket.assigns.clone_source_id
    attrs = Map.take(params, ["name", "description"])

    case clone_version(source_id, attrs) do
      {:ok, version} ->
        audit(socket, "router.version_clone", "router_config", version.id, %{
          "source_config_id" => source_id,
          "name" => version.name
        })

        {:noreply,
         socket
         |> assign(:clone_open, false)
         |> assign(:clone_source_id, nil)
         |> assign(:clone_form, nil)
         |> assign(:clone_errors, [])
         |> put_flash(:info, gettext("Version cloned: %{name}.", name: version.name))
         |> load_versions()
         |> load_use_cases()
         |> load_rules()
         |> push_patch(to: router_path("versions", version.id))}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:noreply,
         socket
         |> assign(:clone_form, to_form(params, as: :clone))
         |> assign(:clone_errors, errors_list(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, clone_error(reason))}
    end
  end

  def handle_event("open_diff_version", _params, socket) do
    default = socket.assigns.default_config
    editing = socket.assigns.editing_config

    {:noreply,
     socket
     |> assign(:diff_open, true)
     |> assign(:diff, Versions.diff_versions(default.id, editing.id))}
  end

  def handle_event("close_diff_version", _params, socket) do
    {:noreply, socket |> assign(:diff_open, false) |> assign(:diff, nil)}
  end

  def handle_event("toggle_archived_versions", _params, socket) do
    {:noreply, assign(socket, :show_archived, not socket.assigns.show_archived)}
  end

  def handle_event("set_shadow", %{"id" => id} = params, socket) do
    # `<.form for={to_form(..., as: :shadow)}>` nests the fields; a hand-fired
    # event still arrives flat, so both shapes are accepted.
    fields = Map.get(params, "shadow", params)
    enabled? = truthy?(fields["shadow_enabled"])
    raw_pct = fields["shadow_sample_pct"]

    cond do
      # Unchecking a shadow without touching the sample: keep the stored value.
      raw_pct in [nil, ""] and not enabled? ->
        apply_shadow(socket, id, false, nil)

      # A silent `nil` here would land on "shadow off" and flash success for a
      # payload the operator never got. Validate before writing anything.
      true ->
        case integer(raw_pct) do
          value when is_integer(value) and value in 1..100 ->
            apply_shadow(socket, id, enabled?, value)

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("The sample must be a whole number between 1 and 100.")
             )}
        end
    end
  end

  def handle_event("open_promote_version", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:promote_open, true) |> assign(:promote_version_id, id)}
  end

  def handle_event("cancel_promote_version", _params, socket) do
    {:noreply, socket |> assign(:promote_open, false) |> assign(:promote_version_id, nil)}
  end

  def handle_event("promote_to_default", %{"id" => id}, socket) do
    case Versions.promote_to_default!(id) do
      {:ok, version} ->
        audit(socket, "router.version_promote", "router_config", version.id, %{
          "previous_default_config_id" => socket.assigns.default_config.id
        })

        {:noreply,
         socket
         |> assign(:promote_open, false)
         |> assign(:promote_version_id, nil)
         |> put_flash(:info, gettext("%{name} is now the serving Default.", name: version.name))
         |> load_all(version.id)
         |> push_patch(to: router_path("versions", version.id))}

      {:error, :archived_version} ->
        {:noreply,
         socket
         |> assign(:promote_open, false)
         |> assign(:promote_version_id, nil)
         |> put_flash(:error, gettext("Restore the version before promoting it."))}
    end
  end

  def handle_event("archive_version", %{"id" => id}, socket) do
    case Versions.archive_version!(id) do
      {:ok, version} ->
        audit(socket, "router.version_archive", "router_config", version.id, %{})

        socket =
          socket
          |> put_flash(:info, gettext("Version archived: %{name}.", name: version.name))
          |> load_versions()

        if socket.assigns.editing_config.id == version.id do
          patch_to(socket, socket.assigns.tab, socket.assigns.default_config.id)
        else
          {:noreply, socket}
        end

      {:error, :cannot_archive_default} ->
        {:noreply, put_flash(socket, :error, gettext("The serving Default cannot be archived."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not archive the version."))}
    end
  end

  def handle_event("unarchive_version", %{"id" => id}, socket) do
    case Versions.unarchive_version!(id) do
      {:ok, version} ->
        audit(socket, "router.version_unarchive", "router_config", version.id, %{})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Version restored: %{name}.", name: version.name))
         |> load_versions()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not restore the version."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Use cases
  # ---------------------------------------------------------------------------

  def handle_event("new_use_case", _params, socket) do
    {:noreply,
     socket
     |> assign(:uc_open, true)
     |> assign(:uc_editing, nil)
     |> assign(:uc_errors, [])
     |> assign(:uc_form, to_form(default_use_case_params(), as: :use_case))}
  end

  def handle_event("edit_use_case", %{"id" => id}, socket) do
    case find_use_case(socket, id) do
      nil ->
        {:noreply, socket}

      use_case ->
        {:noreply,
         socket
         |> assign(:uc_open, true)
         |> assign(:uc_editing, use_case.id)
         |> assign(:uc_errors, [])
         |> assign(:uc_form, to_form(use_case_params(use_case), as: :use_case))}
    end
  end

  def handle_event("cancel_use_case", _params, socket) do
    {:noreply,
     socket
     |> assign(:uc_open, false)
     |> assign(:uc_editing, nil)
     |> assign(:uc_form, nil)
     |> assign(:uc_errors, [])}
  end

  def handle_event("save_use_case", %{"use_case" => params}, socket) do
    attrs = normalize_use_case(params)

    result =
      case socket.assigns.uc_editing do
        nil ->
          attrs = Map.put(attrs, "router_config_id", socket.assigns.editing_config.id)
          %UseCase{} |> UseCase.changeset(attrs) |> Repo.insert()

        id ->
          case find_use_case(socket, id) do
            nil -> {:error, :not_found}
            use_case -> use_case |> UseCase.changeset(attrs) |> Repo.update()
          end
      end

    case result do
      {:ok, use_case} ->
        SmartRouter.invalidate()

        audit(
          socket,
          if(socket.assigns.uc_editing,
            do: "router.use_case_update",
            else: "router.use_case_create"
          ),
          "router_use_case",
          use_case.id,
          %{"key" => use_case.key, "name" => use_case.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Use case saved."))
         |> assign(:uc_open, false)
         |> assign(:uc_editing, nil)
         |> assign(:uc_form, nil)
         |> assign(:uc_errors, [])
         |> load_use_cases()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:uc_form, to_form(params, as: :use_case))
         |> assign(:uc_errors, errors_list(changeset))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("The use case no longer exists."))}
    end
  end

  def handle_event("toggle_use_case", %{"id" => id}, socket) do
    with %UseCase{} = use_case <- find_use_case(socket, id),
         {:ok, updated} <-
           use_case |> UseCase.changeset(%{"enabled" => not use_case.enabled}) |> Repo.update() do
      SmartRouter.invalidate()

      audit(socket, "router.use_case_toggle", "router_use_case", updated.id, %{
        "enabled" => updated.enabled
      })

      {:noreply, load_use_cases(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_destinations", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_uc == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_uc, expanded)}
  end

  # ---------------------------------------------------------------------------
  # Destinations (router_use_case_models)
  # ---------------------------------------------------------------------------

  def handle_event("new_destination", %{"use_case_id" => use_case_id}, socket) do
    {:noreply,
     socket
     |> assign(:dest_open, true)
     |> assign(:dest_editing, nil)
     |> assign(:dest_use_case_id, use_case_id)
     |> assign(:dest_errors, [])
     |> assign(:dest_form, to_form(default_destination_params(), as: :destination))
     |> assign(:expanded_uc, use_case_id)}
  end

  def handle_event("edit_destination", %{"id" => id}, socket) do
    case find_destination(socket, id) do
      nil ->
        {:noreply, socket}

      destination ->
        {:noreply,
         socket
         |> assign(:dest_open, true)
         |> assign(:dest_editing, destination.id)
         |> assign(:dest_use_case_id, destination.router_use_case_id)
         |> assign(:dest_errors, [])
         |> assign(
           :dest_form,
           to_form(destination_params(destination), as: :destination)
         )}
    end
  end

  def handle_event("cancel_destination", _params, socket) do
    {:noreply,
     socket
     |> assign(:dest_open, false)
     |> assign(:dest_editing, nil)
     |> assign(:dest_form, nil)
     |> assign(:dest_errors, [])}
  end

  def handle_event("save_destination", %{"destination" => params}, socket) do
    case parse_flags(params["flags_json"]) do
      :error ->
        {:noreply,
         socket
         |> assign(:dest_form, to_form(params, as: :destination))
         |> assign(:dest_errors, [
           gettext("Flags must be a JSON object, e.g. {\"tier\": \"premium\"}.")
         ])}

      {:ok, flags} ->
        attrs =
          params
          |> Map.put("flags", flags)
          |> Map.put("router_use_case_id", socket.assigns.dest_use_case_id)
          |> normalize_destination()

        result =
          case socket.assigns.dest_editing do
            nil ->
              %UseCaseModel{} |> UseCaseModel.changeset(attrs) |> Repo.insert()

            id ->
              case find_destination(socket, id) do
                nil -> {:error, :not_found}
                destination -> destination |> UseCaseModel.changeset(attrs) |> Repo.update()
              end
          end

        case result do
          {:ok, destination} ->
            SmartRouter.invalidate()

            audit(
              socket,
              if(socket.assigns.dest_editing,
                do: "router.destination_update",
                else: "router.destination_create"
              ),
              "router_use_case_model",
              destination.id,
              %{
                "use_case_id" => destination.router_use_case_id,
                "target_model_id" => destination.target_model_id,
                "effort_tier" => destination.effort_tier
              }
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Destination saved."))
             |> assign(:dest_open, false)
             |> assign(:dest_editing, nil)
             |> assign(:dest_form, nil)
             |> assign(:dest_errors, [])
             |> load_use_cases()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:dest_form, to_form(params, as: :destination))
             |> assign(:dest_errors, errors_list(changeset))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("The destination no longer exists."))}
        end
    end
  end

  def handle_event("toggle_destination", %{"id" => id}, socket) do
    with %UseCaseModel{} = destination <- find_destination(socket, id),
         {:ok, updated} <-
           destination
           |> UseCaseModel.changeset(%{"enabled" => not destination.enabled})
           |> Repo.update() do
      SmartRouter.invalidate()

      audit(socket, "router.destination_toggle", "router_use_case_model", updated.id, %{
        "enabled" => updated.enabled
      })

      {:noreply, load_use_cases(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_destination", %{"id" => id}, socket) do
    case find_destination(socket, id) do
      nil ->
        {:noreply, socket}

      destination ->
        case Repo.delete(destination) do
          {:ok, deleted} ->
            SmartRouter.invalidate()

            audit(socket, "router.destination_delete", "router_use_case_model", deleted.id, %{
              "target_model_id" => deleted.target_model_id,
              "effort_tier" => deleted.effort_tier
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("Destination deleted."))
             |> load_use_cases()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("The destination is still referenced."))}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Rules
  # ---------------------------------------------------------------------------

  def handle_event("new_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_open, true)
     |> assign(:rule_editing, nil)
     |> assign(:rule_errors, [])
     |> reset_rule_pickers()
     |> assign(:rule_form, to_form(default_rule_params(), as: :rule))}
  end

  def handle_event("edit_rule", %{"id" => id}, socket) do
    case find_rule(socket, id) do
      nil ->
        {:noreply, socket}

      rule ->
        {:noreply,
         socket
         |> assign(:rule_open, true)
         |> assign(:rule_editing, rule.id)
         |> assign(:rule_errors, [])
         |> load_rule_pickers(rule)
         |> assign(:rule_form, to_form(rule_params(rule), as: :rule))}
    end
  end

  def handle_event("cancel_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_open, false)
     |> assign(:rule_editing, nil)
     |> assign(:rule_form, nil)
     |> assign(:rule_errors, [])
     |> reset_rule_pickers()}
  end

  # ---------------------------------------------------------------------------
  # Rule match pickers (auto-search + chips)
  # ---------------------------------------------------------------------------

  def handle_event("search_rule_groups", params, socket) do
    search_assigns(socket, :group, search_value(params), &group_choices/1)
  end

  def handle_event("search_rule_services", params, socket) do
    search_assigns(socket, :service, search_value(params), &service_choices/1)
  end

  def handle_event("search_rule_users", params, socket) do
    search_assigns(socket, :user, search_value(params), &user_choices/1)
  end

  def handle_event("add_rule_group", %{"id" => id} = params, socket) do
    add_rule_choice(socket, :group, id, params["label"] || id)
  end

  def handle_event("add_rule_service", %{"id" => id} = params, socket) do
    add_rule_choice(socket, :service, id, params["label"] || id)
  end

  def handle_event("add_rule_user", %{"id" => id} = params, socket) do
    add_rule_choice(socket, :user, id, params["label"] || id)
  end

  def handle_event("remove_rule_group", %{"id" => id}, socket),
    do: remove_rule_choice(socket, :group, id)

  def handle_event("remove_rule_service", %{"id" => id}, socket),
    do: remove_rule_choice(socket, :service, id)

  def handle_event("remove_rule_user", %{"id" => id}, socket),
    do: remove_rule_choice(socket, :user, id)

  def handle_event("close_rule_pickers", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_group_open, false)
     |> assign(:rule_service_open, false)
     |> assign(:rule_user_open, false)}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    attrs = normalize_rule(params, socket)

    result =
      case socket.assigns.rule_editing do
        nil ->
          attrs = Map.put(attrs, "router_config_id", socket.assigns.editing_config.id)
          %Rule{} |> Rule.changeset(attrs) |> Repo.insert()

        id ->
          case find_rule(socket, id) do
            nil -> {:error, :not_found}
            rule -> rule |> Rule.changeset(attrs) |> Repo.update()
          end
      end

    case result do
      {:ok, rule} ->
        SmartRouter.invalidate()

        audit(
          socket,
          if(socket.assigns.rule_editing, do: "router.rule_update", else: "router.rule_create"),
          "router_rule",
          rule.id,
          %{"name" => rule.name, "action" => rule.action, "priority" => rule.priority}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule saved."))
         |> assign(:rule_open, false)
         |> assign(:rule_editing, nil)
         |> assign(:rule_form, nil)
         |> assign(:rule_errors, [])
         |> reset_rule_pickers()
         |> load_rules()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:rule_form, to_form(params, as: :rule))
         |> assign(:rule_errors, errors_list(changeset))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("The rule no longer exists."))}
    end
  end

  def handle_event("toggle_rule", %{"id" => id}, socket) do
    with %Rule{} = rule <- find_rule(socket, id),
         {:ok, updated} <-
           rule |> Rule.changeset(%{"enabled" => not rule.enabled}) |> Repo.update() do
      SmartRouter.invalidate()

      audit(socket, "router.rule_toggle", "router_rule", updated.id, %{
        "enabled" => updated.enabled
      })

      {:noreply, load_rules(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    case find_rule(socket, id) do
      nil ->
        {:noreply, socket}

      rule ->
        case Repo.delete(rule) do
          {:ok, deleted} ->
            SmartRouter.invalidate()

            audit(socket, "router.rule_delete", "router_rule", deleted.id, %{
              "name" => deleted.name
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("Rule deleted."))
             |> load_rules()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the rule."))}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Dry run
  # ---------------------------------------------------------------------------

  def handle_event("run_dry_run", %{"dry" => params}, socket) do
    payload = dry_payload(params)
    editing = socket.assigns.editing_config
    default = socket.assigns.default_config
    analysis = RequestAnalyzer.analyze(payload)
    version_snapshot = version_snapshot(editing, default)
    compare? = truthy?(params["compare_with_default"]) or editing.id != default.id

    rows = if compare?, do: comparison_rows(payload, default, editing), else: nil

    case SmartRouter.dry_run(payload, %{}, snapshot: version_snapshot) do
      {:ok, decision} ->
        {:noreply,
         socket
         |> assign(:dry_form, to_form(params, as: :dry))
         |> assign(:dry_error, nil)
         |> assign(:dry_analysis, analysis)
         |> assign(:dry_result, decision)
         |> assign(:dry_trace, trace_steps(decision, analysis, version_snapshot.config))
         |> assign(:dry_audit, candidate_audit(version_snapshot, analysis, decision))
         |> assign(:dry_comparison, rows)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dry_form, to_form(params, as: :dry))
         |> assign(:dry_error, dry_error_message(reason))
         |> assign(:dry_result, nil)
         |> assign(:dry_trace, [])
         |> assign(:dry_audit, nil)
         |> assign(:dry_comparison, nil)
         |> assign(:dry_analysis, analysis)}
    end
  end

  # ---------------------------------------------------------------------------
  # Live monitor
  # ---------------------------------------------------------------------------

  def handle_event("set_live_filter", %{"filter" => filter}, socket)
      when filter in ["all", "discrepancies"] do
    # Rebuilding from the bounded recent window (instead of only filtering the
    # next event) is what makes the filter honest about what it hides.
    {:noreply, socket |> assign(:live_filter, filter) |> rebuild_live_stream()}
  end

  @impl true
  def handle_info(:router_live_tick, socket) do
    if socket.assigns.tab == "live" do
      Process.send_after(self(), :router_live_tick, @live_tick_ms)

      {:noreply,
       socket
       |> assign(:inflight, visible_inflight())
       |> prune_pulse()}
    else
      # Keep one timer alive for when the operator switches to the tab.
      Process.send_after(self(), :router_live_tick, @live_tick_ms)
      {:noreply, socket}
    end
  end

  def handle_info({:inflight_started, entry}, socket) do
    if socket.assigns.tab == "live" and router_entry?(entry) do
      inflight =
        [entry | Enum.reject(socket.assigns.inflight, &(&1.id == entry.id))]
        |> Enum.take(@inflight_limit)

      {:noreply, assign(socket, :inflight, inflight)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:inflight_done, id}, socket) do
    {:noreply, assign(socket, :inflight, Enum.reject(socket.assigns.inflight, &(&1.id == id)))}
  end

  # A classified request also writes its OWN row (`request_type ==
  # "router_decision"`, billed to the decision model). It is routed and real,
  # but it is not served traffic: it must not appear as a routed request in
  # the monitor, or the operator sees the classifier twice and the pulse
  # inflates.
  def handle_info(
        {:new_log, %{routed_via_router: true, request_type: request_type} = log},
        socket
      )
      when request_type != "router_decision" do
    if socket.assigns.tab == "live" do
      shadows = Map.get(socket.assigns.shadows_by_log_id, Map.get(log, :id), [])
      decorated = decorate_log(log, shadows)
      socket = track_recent_log(socket, log)

      if show_live_log?(socket.assigns.live_filter, decorated) do
        {:noreply,
         socket
         |> stream_insert(:router_events, decorated, at: 0, limit: @stream_limit)
         |> assign(
           :router_events_count,
           min(socket.assigns.router_events_count + 1, @stream_limit)
         )
         |> push_pulse(log)}
      else
        {:noreply, push_pulse(socket, log)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_log, _log}, socket), do: {:noreply, socket}

  # The Shadow evaluator already re-decided a completed request: refresh its
  # row in place when the request is on screen, and remember the evaluations
  # so a later `{:new_log}` for the same id renders them immediately.
  #
  # On any other tab nothing is rendered and nothing will be: remembering one
  # evaluation per logged request here would grow `shadows_by_log_id` with
  # requests the operator never sees. Re-entering the tab re-hydrates the
  # evaluations of the visible window from the reporter.
  def handle_info({:shadow_evaluated, log_id, evals}, socket) when is_list(evals) do
    if socket.assigns.tab == "live" do
      previous = Map.get(socket.assigns.shadows_by_log_id, log_id, [])

      socket =
        assign(
          socket,
          :shadows_by_log_id,
          Map.put(socket.assigns.shadows_by_log_id, log_id, evals)
        )

      case Map.get(socket.assigns.recent_logs, log_id) do
        nil ->
          {:noreply, socket}

        log ->
          decorated = decorate_log(log, evals)

          if show_live_log?(socket.assigns.live_filter, decorated) do
            # A row that only became visible BECAUSE of this verdict (the
            # discrepancy filter hides it until the Shadow disagrees) is a new
            # row on screen: the empty state must not stay above it.
            count =
              if show_live_log?(socket.assigns.live_filter, decorate_log(log, previous)) do
                socket.assigns.router_events_count
              else
                min(socket.assigns.router_events_count + 1, @stream_limit)
              end

            {:noreply,
             socket
             |> stream_insert(:router_events, decorated, at: 0, limit: @stream_limit)
             |> assign(:router_events_count, count)}
          else
            {:noreply, socket}
          end
      end
    else
      # Force a re-hydration on the next visit: the verdict for this request is
      # only in the reporter's table now, not in memory.
      {:noreply, assign(socket, :shadows_hydrated, false)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  defp load_all(socket, version_id) do
    default = default_config()
    versions = Versions.list_versions(include_archived: true)
    editing = pick_editing(versions, version_id, default)

    socket
    |> assign(:default_config, default)
    |> assign(:config, default)
    |> assign(:versions, versions)
    |> assign(:editing_config, editing)
    |> assign(:version_stats, version_stats(versions))
    |> assign(:nav_form, to_form(%{"version" => editing.id}, as: :nav))
    |> load_config()
    |> load_use_cases()
    |> load_rules()
    |> load_model_options()
  end

  defp default_config do
    # `get_default/0` never raises and never inserts; `ensure!/0` creates the
    # sentinel row on a database that was never configured.
    Config.get_default() || Config.ensure!()
  end

  # An unknown, missing or archived-while-selected id falls back to the
  # serving Default: the page must always have a version to render.
  defp pick_editing(versions, version_id, default) do
    case Enum.find(versions, &(&1.id == version_id)) do
      nil -> Enum.find(versions, &(&1.id == default.id)) || default
      version -> version
    end
  end

  defp load_config(socket) do
    default = socket.assigns.default_config
    editing = socket.assigns.editing_config

    socket
    |> assign(:config, default)
    |> assign(:config_form, to_form(config_params(editing, default), as: :config))
    |> assign(:baseline_warning, baseline_warning(default))
  end

  defp load_versions(socket) do
    versions = Versions.list_versions(include_archived: true)

    socket
    |> assign(:versions, versions)
    |> assign(:version_stats, version_stats(versions))
  end

  defp version_stats(versions) do
    use_cases =
      Repo.all(
        from uc in UseCase,
          group_by: uc.router_config_id,
          select: {uc.router_config_id, count(uc.id)}
      )
      |> Map.new()

    rules =
      Repo.all(
        from r in Rule,
          group_by: r.router_config_id,
          select: {r.router_config_id, count(r.id)}
      )
      |> Map.new()

    Map.new(versions, fn version ->
      {version.id,
       %{
         use_cases: Map.get(use_cases, version.id, 0),
         rules: Map.get(rules, version.id, 0)
       }}
    end)
  end

  defp load_use_cases(socket) do
    use_cases =
      Repo.all(
        from uc in UseCase,
          where: uc.router_config_id == ^socket.assigns.editing_config.id,
          order_by: [asc: uc.priority, asc: uc.key],
          preload: [:fallback_model, use_case_models: :target_model]
      )

    assign(socket, :use_cases, use_cases)
  end

  defp load_rules(socket) do
    rules =
      Repo.all(
        from r in Rule,
          where: r.router_config_id == ^socket.assigns.editing_config.id,
          order_by: [asc: r.priority, asc: r.name]
      )

    socket
    |> assign(:rules, rules)
    |> assign(:rule_lookups, rule_lookups(rules))
  end

  defp load_model_options(socket) do
    models = Providers.list_models()

    decision =
      models
      |> Enum.filter(&(&1.model_type == "decision"))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&{"#{&1.name} (decision)", &1.id})

    llm =
      models
      |> Enum.filter(&(&1.model_type == "llm"))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&{&1.name, &1.id})

    socket
    |> assign(:decision_model_options, decision ++ llm)
    |> assign(:llm_model_options, llm)
  end

  # ---------------------------------------------------------------------------
  # Form params
  # ---------------------------------------------------------------------------

  # The config form renders the model pointers as selects whose empty option
  # submits `""`. Ecto dumps `""` into a `:binary_id` and raises, so a blank
  # pointer becomes an explicit `nil` (the field's "no model" state).
  defp blank_model_ids(params) do
    Map.new(params, fn
      {key, ""} when key in ~w(decision_model_id default_model_id baseline_model_id) ->
        {key, nil}

      pair ->
        pair
    end)
  end

  # The kill switch and the baseline are GLOBAL, so they are always rendered
  # from the serving Default even while a candidate is being edited.
  defp config_params(config, default) do
    %{
      "enabled" => default.enabled,
      "policy" => config.policy,
      "decision_timeout_ms" => config.decision_timeout_ms,
      "decision_context_chars" => config.decision_context_chars,
      "fast_path_max_tokens" => config.fast_path_max_tokens,
      "sticky_ttl_seconds" => config.sticky_ttl_seconds,
      "lock_tool_loops" => config.lock_tool_loops,
      "charge_decision_to_subject" => config.charge_decision_to_subject,
      "decision_model_id" => config.decision_model_id || "",
      "default_model_id" => config.default_model_id || "",
      "baseline_model_id" => default.baseline_model_id || ""
    }
  end

  defp default_use_case_params do
    %{
      "key" => "",
      "name" => "",
      "description" => "",
      "tags" => "",
      "priority" => 100,
      "enabled" => true,
      "requires_tools" => false,
      "requires_vision" => false,
      "requires_structured_output" => false,
      "critical_accuracy" => false,
      "allow_downgrade" => true,
      "pin_session" => true,
      "keep_last_n_images" => "",
      "max_history_turns" => "",
      "compact_json" => false,
      "stale_tool_trim_threshold_pct" => "",
      "fallback_model_id" => ""
    }
  end

  defp use_case_params(use_case) do
    %{
      "key" => use_case.key,
      "name" => use_case.name,
      "description" => use_case.description || "",
      "tags" => Enum.join(use_case.tags || [], ", "),
      "priority" => use_case.priority,
      "enabled" => use_case.enabled,
      "requires_tools" => use_case.requires_tools,
      "requires_vision" => use_case.requires_vision,
      "requires_structured_output" => use_case.requires_structured_output,
      "critical_accuracy" => use_case.critical_accuracy,
      "allow_downgrade" => use_case.allow_downgrade,
      "pin_session" => use_case.pin_session,
      "keep_last_n_images" => use_case.keep_last_n_images || "",
      "max_history_turns" => use_case.max_history_turns || "",
      "compact_json" => use_case.compact_json,
      "stale_tool_trim_threshold_pct" => use_case.stale_tool_trim_threshold_pct || "",
      "fallback_model_id" => use_case.fallback_model_id || ""
    }
  end

  defp normalize_use_case(params) do
    %{
      "key" => params["key"],
      "name" => params["name"],
      "description" => params["description"],
      "tags" => list_field(params["tags"]),
      "priority" => integer(params["priority"]) || 100,
      "enabled" => truthy?(params["enabled"]),
      "requires_tools" => truthy?(params["requires_tools"]),
      "requires_vision" => truthy?(params["requires_vision"]),
      "requires_structured_output" => truthy?(params["requires_structured_output"]),
      "critical_accuracy" => truthy?(params["critical_accuracy"]),
      "allow_downgrade" => truthy?(params["allow_downgrade"]),
      "pin_session" => truthy?(params["pin_session"]),
      "keep_last_n_images" => integer(params["keep_last_n_images"]),
      "max_history_turns" => integer(params["max_history_turns"]),
      "compact_json" => truthy?(params["compact_json"]),
      "stale_tool_trim_threshold_pct" => integer(params["stale_tool_trim_threshold_pct"]),
      "fallback_model_id" => blank_to_nil(params["fallback_model_id"])
    }
  end

  defp default_destination_params do
    %{
      "target_model_id" => "",
      "effort_tier" => "any",
      "effort_override" => "",
      "min_confidence" => "",
      "supports_tools" => false,
      "supports_vision" => false,
      "supports_structured_output" => false,
      "tags" => "",
      "flags_json" => "",
      "priority" => 100,
      "enabled" => true
    }
  end

  defp destination_params(destination) do
    %{
      "target_model_id" => destination.target_model_id,
      "effort_tier" => destination.effort_tier,
      "effort_override" => destination.effort_override || "",
      "min_confidence" => decimal_to_string(destination.min_confidence),
      "supports_tools" => destination.supports_tools,
      "supports_vision" => destination.supports_vision,
      "supports_structured_output" => destination.supports_structured_output,
      "tags" => Enum.join(destination.tags || [], ", "),
      "flags_json" => flags_to_json(destination.flags),
      "priority" => destination.priority,
      "enabled" => destination.enabled
    }
  end

  defp normalize_destination(params) do
    %{
      "router_use_case_id" => params["router_use_case_id"],
      "target_model_id" => blank_to_nil(params["target_model_id"]),
      "effort_tier" => params["effort_tier"] || "any",
      "effort_override" => blank_to_nil(params["effort_override"]),
      "min_confidence" => float_or_value(params["min_confidence"]),
      "supports_tools" => truthy?(params["supports_tools"]),
      "supports_vision" => truthy?(params["supports_vision"]),
      "supports_structured_output" => truthy?(params["supports_structured_output"]),
      "tags" => list_field(params["tags"]),
      "flags" => Map.get(params, "flags", %{}),
      "priority" => integer(params["priority"]) || 100,
      "enabled" => truthy?(params["enabled"])
    }
  end

  defp default_rule_params do
    %{
      "name" => "",
      "description" => "",
      "priority" => 100,
      "enabled" => true,
      "action" => "restrict_use_cases",
      "target_use_case_keys" => "",
      "min_tokens" => "",
      "max_tokens" => "",
      "has_tools" => "",
      "has_vision" => "",
      "has_structured_output" => "",
      "reasoning_effort" => "",
      "agent_types" => "",
      "content_regex" => ""
    }
  end

  defp rule_params(rule) do
    conditions = rule.match_conditions || %{}

    %{
      "name" => rule.name,
      "description" => rule.description || "",
      "priority" => rule.priority,
      "enabled" => rule.enabled,
      "action" => rule.action,
      "target_use_case_keys" => Enum.join(rule.target_use_case_keys || [], ", "),
      "min_tokens" => Map.get(conditions, "min_tokens", ""),
      "max_tokens" => Map.get(conditions, "max_tokens", ""),
      "has_tools" => boolean_condition(conditions, "has_tools"),
      "has_vision" => boolean_condition(conditions, "has_vision"),
      "has_structured_output" => boolean_condition(conditions, "has_structured_output"),
      "reasoning_effort" => Map.get(conditions, "reasoning_effort", ""),
      "agent_types" => Enum.join(Map.get(conditions, "agent_types", []), ", "),
      "content_regex" => Map.get(conditions, "content_regex", "")
    }
  end

  defp normalize_rule(params, socket) do
    %{
      "name" => params["name"],
      "description" => params["description"],
      "priority" => integer(params["priority"]) || 100,
      "enabled" => truthy?(params["enabled"]),
      "action" => params["action"],
      "target_use_case_keys" => list_field(params["target_use_case_keys"]),
      "match_conditions" => rule_conditions(params, socket)
    }
  end

  # Only the signals the operator filled become conditions: an empty field is
  # "don't care", exactly what the engine treats a missing key as.
  defp rule_conditions(params, socket) do
    [
      {"min_tokens", integer(params["min_tokens"])},
      {"max_tokens", integer(params["max_tokens"])},
      {"has_tools", boolean_condition_value(params["has_tools"])},
      {"has_vision", boolean_condition_value(params["has_vision"])},
      {"has_structured_output", boolean_condition_value(params["has_structured_output"])},
      {"reasoning_effort", blank_to_nil(params["reasoning_effort"])},
      {"agent_types", list_or_nil(params["agent_types"])},
      {"group_ids", picked_ids_or_nil(socket.assigns.rule_group_ids, params["group_ids"])},
      {"service_ids", picked_ids_or_nil(socket.assigns.rule_service_ids, params["service_ids"])},
      {"user_ids", picked_ids_or_nil(socket.assigns.rule_user_ids, params["user_ids"])},
      {"content_regex", blank_to_nil(params["content_regex"])}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Chips are the source of truth. The raw comma-separated field survives only
  # for a caller that submits `group_ids`/`service_ids`/`user_ids` directly
  # (scripts, older payloads): it is read when no chip was picked.
  defp picked_ids_or_nil([], raw), do: list_or_nil(raw)
  defp picked_ids_or_nil(ids, _raw) when is_list(ids), do: Enum.uniq(ids)

  defp boolean_condition(conditions, key) do
    case Map.get(conditions, key) do
      true -> "true"
      false -> "false"
      _ -> ""
    end
  end

  defp boolean_condition_value("true"), do: true
  defp boolean_condition_value("false"), do: false
  defp boolean_condition_value(true), do: true
  defp boolean_condition_value(false), do: false
  defp boolean_condition_value(_), do: nil

  defp default_dry_params do
    %{
      "prompt" => "",
      "effort" => "",
      "has_tools" => false,
      "has_vision" => false,
      "structured" => false,
      "max_tokens" => "",
      "compare_with_default" => false
    }
  end

  # ---------------------------------------------------------------------------
  # Dry-run payload and trace
  # ---------------------------------------------------------------------------

  defp dry_payload(params) do
    prompt = String.trim(params["prompt"] || "")

    content =
      if truthy?(params["has_vision"]) do
        [
          %{"type" => "text", "text" => prompt},
          %{"type" => "image_url", "image_url" => %{"url" => "https://dry-run.invalid/image.png"}}
        ]
      else
        prompt
      end

    %{"messages" => [%{"role" => "user", "content" => content}]}
    |> put_present(
      "tools",
      truthy?(params["has_tools"]),
      [
        %{
          "type" => "function",
          "function" => %{
            "name" => "lookup",
            "description" => "Dry-run placeholder tool",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ]
    )
    |> put_present(
      "response_format",
      truthy?(params["structured"]),
      %{
        "type" => "json_schema",
        "json_schema" => %{"name" => "out", "schema" => %{"type" => "object"}}
      }
    )
    |> put_present("reasoning_effort", params["effort"] not in [nil, ""], params["effort"])
    |> put_present(
      "max_tokens",
      is_integer(integer(params["max_tokens"])),
      integer(params["max_tokens"])
    )
  end

  defp put_present(map, _key, false, _value), do: map
  defp put_present(map, key, _flag, value), do: Map.put(map, key, value)

  defp trace_steps(decision, analysis, config) do
    meta = decision.decision_meta

    [
      {gettext("Payload"),
       gettext(
         "%{tokens} prompt tokens · tools: %{tools} · vision: %{vision} · structured: %{structured} · effort: %{effort}",
         tokens: analysis.prompt_tokens,
         tools: yes_no(analysis.has_tools),
         vision: yes_no(analysis.has_vision),
         structured: yes_no(analysis.has_structured_output),
         effort: analysis.effort || gettext("none")
       )},
      {gettext("Session pin"),
       if(Map.get(meta, :pinned),
         do: gettext("pinned to %{model}", model: decision.primary.model_name),
         else: gettext("no active pin")
       )},
      {gettext("Rules"),
       case Map.get(meta, :rules, []) do
         [] -> gettext("no rule matched")
         rules -> gettext("matched: %{rules}", rules: Enum.join(rules, ", "))
       end},
      {gettext("Pre-filters"),
       gettext("capability and context-window filters applied to every destination")},
      {gettext("Classifier"), classifier_trace(meta, config)},
      {gettext("Decision source"), source_label(Map.get(meta, :source))},
      {gettext("Winning tier"), decision.primary.effort_tier || gettext("any")},
      {gettext("Fallback chain"),
       case decision.fallbacks do
         [] -> gettext("no fallback (session pin or single candidate)")
         list -> Enum.map_join(list, " → ", & &1.model_name)
       end}
    ]
  end

  defp classifier_trace(meta, config) do
    cond do
      Map.get(meta, :classifier) ->
        gettext("%{model} answered in %{ms} ms (confidence %{confidence})",
          model: Map.get(meta, :model_id) || gettext("decision model"),
          ms: format_ms(Map.get(meta, :classifier_ms)),
          confidence: format_confidence(Map.get(meta, :confidence))
        )

      is_nil(Map.get(config, :decision_model_id)) ->
        gettext("skipped — deterministic (no decision model configured)")

      true ->
        gettext("skipped — deterministic")
    end
  end

  defp yes_no(true), do: gettext("yes")
  defp yes_no(_), do: gettext("no")

  defp format_confidence(nil), do: "—"
  defp format_confidence(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_confidence(value), do: to_string(value)

  defp source_label("session_pin"), do: gettext("Session pin (deterministic)")
  defp source_label("rule"), do: gettext("Rule (deterministic)")
  defp source_label("fast_path"), do: gettext("Fast path (deterministic)")
  defp source_label("single_candidate"), do: gettext("Single viable use case (deterministic)")
  defp source_label("classifier"), do: gettext("Classifier")
  defp source_label("decision_cache"), do: gettext("Classifier cache hit")
  defp source_label(other), do: other || "—"

  defp dry_error_message(:router_disabled),
    do: gettext("The router is disabled. Enable it in the Engine tab to dry-run.")

  defp dry_error_message(:no_candidates),
    do:
      gettext(
        "No use case has an eligible destination for this payload. Bind models to a use case (Engine tab) or relax its requirements."
      )

  defp dry_error_message(reason),
    do: gettext("The dry run failed: %{reason}", reason: inspect(reason))

  # Candidate audit: walks the snapshot with the same capability/context-window
  # rules the engine applies in Layer 1, so the dry run can show *why* each
  # destination was discarded instead of only the winner.
  defp candidate_audit(snapshot, analysis, decision) do
    winner_key = decision.use_case && decision.use_case.key

    rows =
      for use_case <- Map.get(snapshot, :use_cases, []),
          candidate <- Map.get(use_case, :candidates, []) do
        reason = reject_reason(use_case, candidate, analysis)

        %{
          use_case_key: use_case.key,
          use_case_name: use_case.name,
          use_case_priority: use_case.priority,
          model_name: candidate.model_name,
          tier: candidate.effort_tier,
          reason: reason,
          selected:
            is_nil(reason) and use_case.key == winner_key and
              candidate.model_id == decision.primary.model_id
        }
      end

    %{
      eligible: Enum.filter(rows, &is_nil(&1.reason)),
      discarded: Enum.filter(rows, &(!is_nil(&1.reason)))
    }
  end

  # The candidate must support what the use case REQUIRES **or** what the
  # payload actually carries: a dry-run with tools must not land on a model
  # without tool support just because the use case was not flagged
  # `requires_tools`. Without this, the audit claims a destination is eligible
  # while the engine would have filtered it in Layer 1 — the exact lie a dry
  # run exists to prevent.
  defp reject_reason(use_case, candidate, analysis) do
    cond do
      Map.get(candidate, :enabled) == false ->
        gettext("destination disabled")

      capability_missing?(use_case, analysis, candidate, :tools) ->
        gettext("the use case requires tool support")

      capability_missing?(use_case, analysis, candidate, :vision) ->
        gettext("the use case requires vision support")

      capability_missing?(use_case, analysis, candidate, :structured_output) ->
        gettext("the use case requires structured output")

      true ->
        context_window_reason(candidate, analysis)
    end
  end

  defp capability_missing?(use_case, analysis, candidate, :tools),
    do:
      needed?(use_case, analysis, :requires_tools, :has_tools) and
        not Map.get(candidate, :supports_tools)

  defp capability_missing?(use_case, analysis, candidate, :vision),
    do:
      needed?(use_case, analysis, :requires_vision, :has_vision) and
        not Map.get(candidate, :supports_vision)

  defp capability_missing?(use_case, analysis, candidate, :structured_output),
    do:
      needed?(use_case, analysis, :requires_structured_output, :has_structured_output) and
        not Map.get(candidate, :supports_structured_output)

  defp needed?(use_case, analysis, required_key, present_key),
    do: Map.get(use_case, required_key) == true or Map.get(analysis, present_key) == true

  defp context_window_reason(candidate, analysis) do
    needed = analysis.prompt_tokens + analysis.estimated_output_tokens

    case Map.get(candidate, :context_window) do
      window when is_integer(window) and window < needed ->
        gettext("context window too small (%{window} < %{needed} tokens)",
          window: window,
          needed: needed
        )

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Version helpers
  # ---------------------------------------------------------------------------

  defp router_path(tab, version_id) when is_binary(version_id) do
    "/catalog/router?tab=#{tab}&version=#{version_id}"
  end

  defp patch_to(socket, tab, version_id) do
    {:noreply, push_patch(socket, to: router_path(tab, version_id))}
  end

  # The switcher submits its own form (`nav[version]`); a direct
  # `phx-click="select_version"` may send a bare `version`.
  defp version_param(%{"nav" => %{"version" => id}}) when is_binary(id), do: id
  defp version_param(%{"version" => id}) when is_binary(id), do: id
  defp version_param(_params), do: nil

  defp version_options(versions, show_archived, editing, default_id) do
    versions
    |> Enum.filter(fn version ->
      show_archived or is_nil(version.archived_at) or version.id == editing.id
    end)
    |> Enum.map(fn version ->
      {"#{version.name} · #{version_state_label(version, default_id)}", version.id}
    end)
  end

  # The Versions table always shows the non-archived versions plus the one being
  # edited (even if it is archived, so the operator can restore it in place).
  defp visible_versions(versions, show_archived, editing) do
    Enum.filter(versions, fn version ->
      show_archived or is_nil(version.archived_at) or version.id == editing.id
    end)
  end

  defp version_state(version, default_id) do
    cond do
      version.id == default_id -> :default
      version.archived_at -> :archived
      version.shadow_enabled -> :shadow
      true -> :draft
    end
  end

  defp version_state_label(version, default_id) do
    case version_state(version, default_id) do
      :default -> gettext("Default · serving")
      :archived -> gettext("Archived")
      :shadow -> gettext("Shadow %{pct}%", pct: version.shadow_sample_pct || 100)
      :draft -> gettext("Draft")
    end
  end

  defp version_state_class(version, default_id) do
    case version_state(version, default_id) do
      :default -> "badge-success"
      :archived -> "badge-ghost"
      :shadow -> "badge-info"
      :draft -> "badge-warning"
    end
  end

  defp model_label(_options, nil), do: gettext("none")

  defp model_label(options, model_id) do
    case Enum.find(options, fn {_label, id} -> id == model_id end) do
      {label, _id} -> label
      nil -> model_id
    end
  end

  defp apply_shadow(socket, id, enabled?, pct) do
    case Versions.toggle_shadow!(id, enabled?, pct) do
      {:ok, version} ->
        audit(socket, "router.version_shadow", "router_config", version.id, %{
          "shadow_enabled" => version.shadow_enabled,
          "shadow_sample_pct" => version.shadow_sample_pct
        })

        {:noreply,
         socket
         |> put_flash(:info, shadow_flash(version))
         |> load_versions()}

      {:error, :cannot_shadow_default} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The serving Default cannot be a shadow: it is already what traffic runs on.")
         )}

      {:error, :archived_version} ->
        {:noreply,
         put_flash(socket, :error, gettext("An archived version cannot evaluate live traffic."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The sample must be a whole number between 1 and 100.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the shadow version."))}
    end
  end

  # The shadow toggle of ONE candidate. It is a Phoenix `<.form>` driven by an
  # explicit `to_form/2` (never a raw changeset in the template) so the sample
  # is validated as a number in 1..100 before `set_shadow` writes anything.
  attr :version, :map, required: true

  defp shadow_controls(assigns) do
    version = assigns.version

    form =
      to_form(
        %{
          "shadow_enabled" => version.shadow_enabled || false,
          "shadow_sample_pct" => version.shadow_sample_pct || 100
        },
        as: :shadow
      )

    assigns = assign(assigns, :form, form)

    ~H"""
    <.form
      for={@form}
      id={"shadow-form-#{@version.id}"}
      phx-submit="set_shadow"
      phx-value-id={@version.id}
      class="flex flex-wrap items-center gap-2"
    >
      <.input
        field={@form[:shadow_enabled]}
        type="checkbox"
        id={"shadow-toggle-#{@version.id}"}
        label={gettext("Shadow")}
        class="checkbox checkbox-xs"
      />
      <.input
        field={@form[:shadow_sample_pct]}
        type="number"
        min="1"
        max="100"
        id={"shadow-sample-#{@version.id}"}
        class="input input-xs w-16"
        aria-label={gettext("Sample %")}
      />
      <span class="text-xs text-base-content/50">%</span>
      <button type="submit" id={"save-shadow-#{@version.id}"} class="btn btn-xs btn-ghost">
        {gettext("Apply")}
      </button>
      <p
        :if={@version.decision_model_id}
        id={"shadow-classifier-note-#{@version.id}"}
        class="text-xs text-base-content/50 w-full"
      >
        {gettext(
          "This version has a decision model: its classifier also runs in parallel and its cost is recorded, never billed."
        )}
      </p>
    </.form>
    """
  end

  defp shadow_flash(%Config{shadow_enabled: true} = version) do
    gettext("Shadow evaluation on for %{name} at %{pct}% of sampled traffic.",
      name: version.name,
      pct: version.shadow_sample_pct
    )
  end

  defp shadow_flash(version) do
    gettext("Shadow evaluation off for %{name}.", name: version.name)
  end

  # `Versions.clone_version!/2` raises on an invalid changeset (a blank name):
  # the modal wants that changeset back as a form error, not a crash.
  defp clone_version(nil, _attrs), do: {:error, :missing_source}

  defp clone_version(source_id, attrs) do
    {:ok, Versions.clone_version!(source_id, attrs)}
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp clone_error(:missing_source),
    do: gettext("The source version no longer exists.")

  defp clone_error(_reason), do: gettext("Could not clone the version.")

  defp diff_status_label(:only_in_left), do: gettext("only in the Default")
  defp diff_status_label(:only_in_right), do: gettext("only in this version")
  defp diff_status_label(:changed), do: gettext("changed")

  defp diff_status_class(:only_in_left), do: "badge-error"
  defp diff_status_class(:only_in_right), do: "badge-success"
  defp diff_status_class(:changed), do: "badge-warning"

  defp diff_value(nil), do: "—"
  defp diff_value(value) when is_boolean(value), do: to_string(value)
  defp diff_value(value) when is_list(value), do: Enum.join(Enum.map(value, &to_string/1), ", ")
  defp diff_value(value) when is_map(value), do: Jason.encode!(value)
  defp diff_value(value), do: to_string(value)

  # ---------------------------------------------------------------------------
  # Dry-run comparison
  # ---------------------------------------------------------------------------

  # A candidate is decided against its OWN catalogue; the Default against its
  # own. The Default's snapshot is the cached one (`config_id: nil` key).
  #
  # `enabled` is GLOBAL and lives on the serving Default: a candidate keeps its
  # own stale value in its row, so deciding it as-is would answer
  # `:router_disabled` while traffic is actually being routed.
  defp version_snapshot(editing, default) do
    if editing.id == default.id do
      SmartRouter.snapshot()
    else
      SmartRouter.snapshot(config_id: editing.id)
      |> Map.update(:config, nil, fn
        nil -> nil
        config -> Map.put(config, :enabled, default.enabled)
      end)
    end
  end

  defp comparison_rows(payload, default, editing) do
    default_side = dry_side(payload, default, SmartRouter.snapshot())
    version_side = dry_side(payload, editing, version_snapshot(editing, default))

    %{
      default_name: default.name,
      version_name: editing.name,
      default: default_side,
      version: version_side
    }
  end

  defp dry_side(payload, config, snapshot) do
    case SmartRouter.dry_run(payload, %{}, snapshot: snapshot) do
      {:ok, decision} ->
        %{
          ok: true,
          error: nil,
          use_case: decision.use_case && decision.use_case.key,
          use_case_name: decision.use_case && decision.use_case.name,
          tier: decision.primary.effort_tier,
          model: decision.primary.model_name,
          model_id: decision.primary.model_id,
          config_name: config.name
        }

      {:error, reason} ->
        %{ok: false, error: dry_error_message(reason), use_case: nil, tier: nil, model: nil}
    end
  end

  defp comparison_same_use_case?(comparison) do
    comparison.default.use_case != nil and
      comparison.default.use_case == comparison.version.use_case
  end

  defp comparison_same_tier?(comparison) do
    comparison.default.tier == comparison.version.tier
  end

  defp comparison_same_model?(comparison) do
    comparison.default.model_id != nil and
      comparison.default.model_id == comparison.version.model_id
  end

  # ---------------------------------------------------------------------------
  # Rule picker helpers (auto-search + chips)
  # ---------------------------------------------------------------------------

  defp reset_rule_pickers(socket) do
    Enum.reduce([:group, :service, :user], socket, fn kind, acc ->
      acc
      |> assign(:"rule_#{kind}_ids", [])
      |> assign(:"rule_#{kind}_names", %{})
      |> assign(:"rule_#{kind}_search", "")
      |> assign(:"rule_#{kind}_results", [])
      |> assign(:"rule_#{kind}_open", false)
    end)
  end

  defp load_rule_pickers(socket, rule) do
    conditions = rule.match_conditions || %{}
    group_ids = condition_ids(conditions, "group_ids")
    service_ids = condition_ids(conditions, "service_ids")
    user_ids = condition_ids(conditions, "user_ids")

    socket
    |> reset_rule_pickers()
    |> assign(:rule_group_ids, group_ids)
    |> assign(:rule_service_ids, service_ids)
    |> assign(:rule_user_ids, user_ids)
    |> assign(:rule_group_names, group_names(group_ids))
    |> assign(:rule_service_names, service_names(service_ids))
    |> assign(:rule_user_names, user_names(user_ids))
  end

  defp condition_ids(conditions, key) do
    case Map.get(conditions, key) do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  # `phx-change` on a plain input sends its own name; a change on the whole
  # form nests it. Older payloads may use `value`/`q`.
  defp search_value(params) do
    raw =
      params["value"] || params["q"] || params["search"] ||
        case Enum.find(params, fn {key, value} -> is_binary(value) and key != "_target" end) do
          {_key, value} -> value
          nil -> ""
        end

    if is_binary(raw), do: String.trim(raw), else: ""
  end

  defp search_assigns(socket, kind, search, fetcher) do
    results = if search == "", do: [], else: fetcher.(search)

    {:noreply,
     socket
     |> assign(:"rule_#{kind}_search", search)
     |> assign(:"rule_#{kind}_results", results)
     |> assign(:"rule_#{kind}_open", search != "")}
  end

  defp add_rule_choice(socket, kind, id, label) do
    ids = socket.assigns[:"rule_#{kind}_ids"] || []
    names = socket.assigns[:"rule_#{kind}_names"] || %{}

    {:noreply,
     socket
     |> assign(:"rule_#{kind}_ids", Enum.uniq(ids ++ [id]))
     |> assign(:"rule_#{kind}_names", Map.put(names, id, label))
     |> assign(:"rule_#{kind}_search", "")
     |> assign(:"rule_#{kind}_results", [])
     |> assign(:"rule_#{kind}_open", false)}
  end

  defp remove_rule_choice(socket, kind, id) do
    ids = Enum.reject(socket.assigns[:"rule_#{kind}_ids"] || [], &(&1 == id))
    names = Map.delete(socket.assigns[:"rule_#{kind}_names"] || %{}, id)

    {:noreply,
     socket
     |> assign(:"rule_#{kind}_ids", ids)
     |> assign(:"rule_#{kind}_names", names)}
  end

  defp group_choices(query) do
    Accounts.list_groups_page(search: query, per_page: 8).entries
    |> Enum.map(&%{id: &1.id, label: &1.name, hint: gettext("Limit profile")})
  end

  defp service_choices(query) do
    Accounts.list_services_page(search: query, per_page: 8).entries
    |> Enum.map(&%{id: &1.id, label: &1.name, hint: gettext("Service")})
  end

  defp user_choices(query) do
    Accounts.list_users_page(search: query, per_page: 8).entries
    |> Enum.map(fn user ->
      %{
        id: user.id,
        label: user.name || user.email,
        hint: user.name && user.email
      }
    end)
  end

  defp rule_lookups(rules) do
    {group_ids, service_ids, user_ids} =
      Enum.reduce(rules, {[], [], []}, fn rule, {groups, services, users} ->
        conditions = rule.match_conditions || %{}

        {groups ++ condition_ids(conditions, "group_ids"),
         services ++ condition_ids(conditions, "service_ids"),
         users ++ condition_ids(conditions, "user_ids")}
      end)

    %{
      groups: group_names(group_ids),
      services: service_names(service_ids),
      users: user_names(user_ids)
    }
  end

  defp group_names([]), do: %{}

  defp group_names(ids) do
    Repo.all(from g in Group, where: g.id in ^Enum.uniq(ids), select: {g.id, g.name})
    |> Map.new()
  end

  defp service_names([]), do: %{}

  defp service_names(ids) do
    Repo.all(from s in Service, where: s.id in ^Enum.uniq(ids), select: {s.id, s.name})
    |> Map.new()
  end

  defp user_names([]), do: %{}

  defp user_names(ids) do
    Repo.all(
      from u in User,
        where: u.id in ^Enum.uniq(ids),
        select: {u.id, fragment("COALESCE(NULLIF(?, ''), ?)", u.name, u.email)}
    )
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Live monitor helpers
  # ---------------------------------------------------------------------------

  # Only requests that actually went through the router: this monitor has no
  # business showing direct traffic, and the in-flight registry is shared with
  # the global Logs page.
  defp router_entry?(entry), do: Map.get(entry, :routed_via_router) == true

  defp visible_inflight do
    Inflight.list()
    |> Enum.filter(&router_entry?/1)
    |> Enum.take(@inflight_limit)
  end

  defp empty_pulse do
    %{
      requests: 0,
      per_minute: 0.0,
      avg_tps: nil,
      fallbacks: 0,
      errors: 0,
      window_seconds: @pulse_window_seconds
    }
  end

  defp push_pulse(socket, log) do
    entry = %{
      at: DateTime.utc_now(),
      tps: log_tps(log),
      fallback: Map.get(log, :router_decision_source) in ["fallback_timeout", "fallback_error"],
      error: (Map.get(log, :status_code) || 0) >= 400
    }

    entries =
      [entry | socket.assigns.pulse_entries]
      |> Enum.filter(&(DateTime.diff(DateTime.utc_now(), &1.at) <= @pulse_window_seconds))

    assign(socket, :pulse_entries, entries)
    |> assign(:pulse, summarize_pulse(entries))
  end

  defp prune_pulse(socket) do
    entries =
      Enum.filter(
        socket.assigns.pulse_entries,
        &(DateTime.diff(DateTime.utc_now(), &1.at) <= @pulse_window_seconds)
      )

    assign(socket, :pulse_entries, entries) |> assign(:pulse, summarize_pulse(entries))
  end

  defp summarize_pulse(entries) do
    tps_values = entries |> Enum.map(& &1.tps) |> Enum.reject(&is_nil/1)

    %{
      requests: length(entries),
      per_minute: Float.round(length(entries) * 60 / @pulse_window_seconds, 1),
      avg_tps:
        case tps_values do
          [] -> nil
          values -> Float.round(Enum.sum(values) / length(values), 1)
        end,
      fallbacks: Enum.count(entries, & &1.fallback),
      errors: Enum.count(entries, & &1.error),
      window_seconds: @pulse_window_seconds
    }
  end

  # The stream carries a decorated copy: the raw log already has everything,
  # but `:dom_id` gives the row a stable DOM id that the template can use and
  # `:shadows` carries the version evaluations recorded for that request.
  defp decorate_log(log, shadows) do
    log
    |> ensure_map()
    |> Map.put(:dom_id, "router-log-#{Map.get(log, :id) || System.unique_integer([:positive])}")
    |> Map.put(:shadows, shadows || [])
  end

  # Bounded memory of what is on screen, so a `{:shadow_evaluated, ...}`
  # arriving after the log row can be matched back to it. `recent_refs` is the
  # ordered (newest first) key list: both maps are pruned against it, which is
  # what keeps `shadows_by_log_id` from outliving the window it describes.
  defp track_recent_log(socket, log) do
    with id when is_binary(id) <- Map.get(log, :id),
         %DateTime{} = inserted_at <- Map.get(log, :inserted_at) do
      refs =
        [{id, inserted_at} | Enum.reject(socket.assigns.recent_refs, &(elem(&1, 0) == id))]
        |> Enum.take(@stream_limit)

      ids = Enum.map(refs, &elem(&1, 0))

      socket
      |> assign(:recent_refs, refs)
      |> assign(:recent_logs, Map.take(Map.put(socket.assigns.recent_logs, id, log), ids))
      |> assign(:shadows_by_log_id, Map.take(socket.assigns.shadows_by_log_id, ids))
    else
      _ -> socket
    end
  end

  # On the first visit to the Live tab, backfill the evaluations the reporter
  # recorded before this LiveView subscribed.
  defp hydrate_shadows(socket) do
    if socket.assigns.shadows_hydrated do
      socket
    else
      shadows =
        case socket.assigns.recent_refs do
          [] -> %{}
          refs -> Analytics.shadow_for_logs(refs)
        end

      socket
      |> assign(:shadows_by_log_id, Map.merge(shadows, socket.assigns.shadows_by_log_id))
      |> assign(:shadows_hydrated, true)
    end
  end

  defp show_live_log?("all", _log), do: true
  defp show_live_log?(_filter, log), do: discrepant?(Map.get(log, :shadows) || [])

  # The stream is re-derived from the bounded recent window (newest first).
  # Rows live in the socket process across tabs, but the DOM container does
  # not, so entering the tab (or changing the filter) replays them instead of
  # trusting whatever the client kept.
  defp rebuild_live_stream(socket) do
    rows =
      socket.assigns.recent_refs
      |> Enum.flat_map(fn {id, _inserted_at} ->
        case Map.get(socket.assigns.recent_logs, id) do
          nil -> []
          log -> [decorate_log(log, Map.get(socket.assigns.shadows_by_log_id, id, []))]
        end
      end)
      |> Enum.filter(&show_live_log?(socket.assigns.live_filter, &1))

    socket
    |> stream(:router_events, rows, reset: true)
    |> assign(:router_events_count, length(rows))
  end

  # A disagreement is a request the candidate would have routed to another
  # model or another effort tier; an errored evaluation carries no decision and
  # is never counted as a discrepancy.
  defp discrepant?(shadows) do
    Enum.any?(shadows, fn shadow ->
      is_nil(field(shadow, :error_reason)) and
        (field(shadow, :matches_default_model) == false or
           field(shadow, :matches_default_tier) == false)
    end)
  end

  defp shadow_match_label(shadow) do
    cond do
      field(shadow, :error_reason) -> gettext("error")
      field(shadow, :matches_default_model) == false -> gettext("different model")
      field(shadow, :matches_default_tier) == false -> gettext("different tier")
      true -> gettext("= equal")
    end
  end

  defp shadow_match_class(shadow) do
    cond do
      field(shadow, :error_reason) -> "badge-error"
      field(shadow, :matches_default_model) == false -> "badge-warning"
      field(shadow, :matches_default_tier) == false -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp shadow_model_label(shadow), do: field(shadow, :model_name) || gettext("no decision")

  defp shadow_config_id(shadow), do: field(shadow, :shadow_config_id) || "unknown"

  defp field(%_{} = struct, key), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp ensure_map(%_{} = struct), do: Map.from_struct(struct)
  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp log_tps(log) do
    completion = Map.get(log, :completion_tokens) || 0
    latency = Map.get(log, :latency_ms) || 0
    ttft = Map.get(log, :ttft_ms) || 0
    window = max(latency - ttft, 1)

    if completion > 0 do
      Float.round(completion / window * 1_000, 1)
    end
  end

  defp subject_label(log) do
    cond do
      Map.get(log, :subject_type) == "service" ->
        dig(log, [:service, :name]) || gettext("Service")

      true ->
        dig(log, [:group_member, :user, :email]) || dig(log, [:user, :email]) ||
          gettext("User")
    end
  end

  defp group_label(log) do
    dig(log, [:group_member, :group, :name]) || dig(log, [:group, :name])
  end

  defp provider_label(log) do
    dig(log, [:provider, :name]) || Map.get(log, :provider_name)
  end

  defp dig(value, []), do: value

  defp dig(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, nil} -> nil
      {:ok, next} -> dig(next, rest)
      :error -> nil
    end
  end

  defp dig(_value, _keys), do: nil

  # ---------------------------------------------------------------------------
  # Lookups and coercions
  # ---------------------------------------------------------------------------

  defp find_use_case(socket, id) do
    Enum.find(socket.assigns.use_cases, &(&1.id == id))
  end

  defp find_destination(socket, id) do
    Enum.find_value(socket.assigns.use_cases, fn use_case ->
      Enum.find(use_case.use_case_models, &(&1.id == id))
    end) || Repo.get(UseCaseModel, id)
  end

  defp find_rule(socket, id) do
    Enum.find(socket.assigns.rules, &(&1.id == id))
  end

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp integer(nil), do: nil
  defp integer(""), do: nil
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> value
    end
  end

  defp integer(_), do: nil

  defp float_or_value(nil), do: nil
  defp float_or_value(""), do: nil
  defp float_or_value(value) when is_float(value) or is_integer(value), do: value

  defp float_or_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> value
    end
  end

  defp float_or_value(value), do: value

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp list_field(value) when is_list(value), do: value

  defp list_field(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list_field(_), do: []

  defp list_or_nil(value) do
    case list_field(value) do
      [] -> nil
      list -> list
    end
  end

  defp parse_flags(nil), do: {:ok, %{}}
  defp parse_flags(value) when is_map(value), do: {:ok, value}

  defp parse_flags(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:ok, %{}}
    else
      case Jason.decode(value) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _ -> :error
      end
    end
  end

  defp parse_flags(_), do: :error

  defp flags_to_json(flags) when is_map(flags) and map_size(flags) > 0, do: Jason.encode!(flags)
  defp flags_to_json(_), do: ""

  defp decimal_to_string(nil), do: ""

  defp decimal_to_string(%Decimal{} = value) do
    value |> Decimal.to_string(:normal) |> String.trim_trailing(".")
  end

  defp decimal_to_string(value), do: to_string(value)

  defp errors_list(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  # ---------------------------------------------------------------------------
  # Baseline pricing
  # ---------------------------------------------------------------------------

  defp baseline_warning(%Config{baseline_model_id: nil}), do: nil

  defp baseline_warning(%Config{baseline_model_id: id}) do
    case Providers.get_model(id) do
      nil ->
        gettext("The baseline model no longer exists: net savings cannot be priced.")

      model ->
        lanes = baseline_lanes(model.id)

        cond do
          lanes == [] ->
            gettext("The baseline model has no active global lane: net savings cannot be priced.")

          Enum.any?(lanes, &priced_lane?/1) ->
            nil

          true ->
            gettext(
              "No lane of the baseline model carries a price: baseline coverage and net savings will stay empty."
            )
        end
    end
  end

  # The baseline is a counterfactual for EVERY routed request, so only a lane
  # every consumer can reach counts: an exclusive lane (member/group/service)
  # prices just that target and would leave the rest of the traffic unpriced,
  # and a revoked key prices nothing at all — the row would look priced while
  # coverage stayed empty.
  defp baseline_lanes(model_id) do
    model_id
    |> Providers.list_all_model_providers()
    |> Enum.filter(& &1.enabled)
    |> Enum.filter(&global_lane?/1)
    |> Enum.filter(&active_credential?/1)
  end

  defp global_lane?(lane) do
    is_nil(lane.exclusive_to_group_member_id) and is_nil(lane.exclusive_to_group_id) and
      is_nil(lane.exclusive_to_service_id)
  end

  defp active_credential?(%{credential: %{status: "active"}}), do: true

  # A pool lane has no single credential: it rotates over its members, so one
  # live member is enough for the lane to serve.
  defp active_credential?(%{pool: %{members: members}}) when is_list(members) do
    Enum.any?(members, &match?(%{credential: %{status: "active"}}, &1))
  end

  defp active_credential?(_lane), do: false

  # Every token-denominated unit (`per_1m_tokens`, `per_1k_tokens`, …) is
  # priced by the three `*_cost_per_million` columns; anything else bills
  # through `unit_cost`.
  defp priced_lane?(lane) do
    if Pricing.token_unit?(lane.pricing_unit) do
      not is_nil(lane.input_cost_per_million) and not is_nil(lane.output_cost_per_million)
    else
      not is_nil(lane.unit_cost)
    end
  end

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  defp use_case_flags(use_case) do
    [
      {use_case.requires_tools, gettext("tools")},
      {use_case.requires_vision, gettext("vision")},
      {use_case.requires_structured_output, gettext("structured")},
      {use_case.critical_accuracy, gettext("critical")},
      {!use_case.allow_downgrade, gettext("no downgrade")},
      {use_case.compact_json, gettext("compact json")}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp rule_conditions_summary(rule, lookups) do
    rule.match_conditions
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} ->
      "#{key}=#{condition_value(value, to_string(key), lookups)}"
    end)
  end

  defp condition_value(value, "group_ids", lookups) when is_list(value),
    do: resolve_names(value, lookups.groups)

  defp condition_value(value, "service_ids", lookups) when is_list(value),
    do: resolve_names(value, lookups.services)

  defp condition_value(value, "user_ids", lookups) when is_list(value),
    do: resolve_names(value, lookups.users)

  defp condition_value(value, _key, _lookups) when is_list(value), do: Enum.join(value, "|")
  defp condition_value(value, _key, _lookups), do: to_string(value)

  # A deleted profile/service/user must stay visible as its id: showing a blank
  # chip would hide that the rule targets something that no longer exists.
  defp resolve_names(ids, names) do
    Enum.map_join(ids, "|", fn id -> Map.get(names, id, id) end)
  end

  defp destination_label(destination) do
    case destination.target_model do
      nil -> destination.target_model_id
      model -> "#{model.name} · #{destination.effort_tier}"
    end
  end

  defp policy_options, do: Enum.map(Config.policies(), &{policy_label(&1), &1})

  defp policy_label("cost_first"), do: gettext("Cost first")
  defp policy_label("balanced"), do: gettext("Balanced")
  defp policy_label("quality_first"), do: gettext("Quality first")
  defp policy_label("latency_first"), do: gettext("Latency first")
  defp policy_label(other), do: other

  defp effort_options do
    [
      {gettext("Client default"), ""},
      {gettext("Low"), "low"},
      {gettext("Medium"), "medium"},
      {gettext("High"), "high"}
    ]
  end

  # Cost of one completed routed request against the counterfactual the router
  # priced for it: negative savings (escalation) is shown as "over", never
  # clipped at zero.
  defp cost_vs_baseline(log) do
    cost =
      decimal_sum(Map.get(log, :provider_cost_usd), Map.get(log, :router_decision_cost_usd))

    case Map.get(log, :router_baseline_cost_usd) do
      nil ->
        "—"

      baseline ->
        diff = Decimal.sub(baseline, cost)

        if Decimal.negative?(diff) do
          gettext("%{amount} over", amount: Stats.money(Decimal.abs(diff)))
        else
          gettext("%{amount} saved", amount: Stats.money(diff))
        end
    end
  end

  defp request_cost(log) do
    decimal_sum(Map.get(log, :provider_cost_usd), Map.get(log, :router_decision_cost_usd))
  end

  defp decimal_sum(a, b) do
    Decimal.add(to_decimal(a), to_decimal(b))
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(nil), do: Decimal.new(0)

  defp to_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _rest} -> decimal
      :error -> Decimal.new(0)
    end
  end

  defp to_decimal(value) when is_integer(value) or is_float(value),
    do: Decimal.from_float(value * 1.0)

  defp to_decimal(_), do: Decimal.new(0)

  defp seconds_ago(%DateTime{} = started_at) do
    DateTime.utc_now() |> DateTime.diff(started_at, :second) |> max(0)
  end

  defp seconds_ago(_), do: 0

  # Money/format delegates so the template reads like the rest of /stats.
  defp money(value), do: Stats.money(value)
  defp format_number(value), do: Stats.format_number(value)
  defp format_ms(value), do: Stats.format_ms(value)
  defp format_tps(value), do: Stats.format_tps(value)
end
