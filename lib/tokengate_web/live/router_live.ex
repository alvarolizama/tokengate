defmodule TokengateWeb.RouterLive do
  @moduledoc """
  Admin surface of the SmartRouter (`/catalog/router`).

  Four URL-addressable tabs (`?tab=engine|rules|dry_run|live`, default
  `engine`), so an operator can bookmark the dry-run or leave the live monitor
  open on a second screen:

    * `engine`  — the singleton `router_configs` row, the use cases
      (`router_use_cases`) and, per use case, its effort-tiered destinations
      (`router_use_case_models`).
    * `rules`   — the prioritized deterministic layer (`router_rules`).
    * `dry_run` — one payload through `Tokengate.SmartRouter.dry_run/3`: no
      upstream call, no session pin, no budget movement. Prints the matched use
      case, effort tier, rule/pre-filter trace, discarded candidates with their
      reason, the classifier's answer (or "skipped — deterministic"), the
      prompt-saving preview and the fallback chain.
    * `live`    — PubSub-driven monitor: `Inflight.topic()` for requests in
      flight and `"logs:new"` for completed routed requests, with a bounded
      stream (`limit: 100`).

  Every mutation calls `Tokengate.SmartRouter.invalidate/0` (the snapshot lives
  one minute in `Tokengate.Cache`) and writes an audit entry through
  `TokengateWeb.Audit`, exactly like the rest of the admin screens.
  """
  use TokengateWeb, :live_view

  import Ecto.Query, warn: false

  alias Tokengate.Logs.Inflight
  alias Tokengate.Providers
  alias Tokengate.Providers.Pricing
  alias Tokengate.Repo
  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.{Config, Presets, RequestAnalyzer, Rule, UseCase, UseCaseModel}
  alias TokengateWeb.StatsHelpers, as: Stats

  @tabs ~w(engine rules dry_run live)

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
      |> assign(:dry_form, to_form(default_dry_params(), as: :dry))
      |> assign(:dry_result, nil)
      |> assign(:dry_error, nil)
      |> assign(:dry_trace, [])
      |> assign(:dry_audit, nil)
      |> assign(:dry_analysis, nil)
      |> assign(:inflight, [])
      |> assign(:pulse, empty_pulse())
      |> assign(:pulse_entries, [])
      |> assign(:router_events_count, 0)
      |> stream(:router_events, [], reset: true)
      |> load_all()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
      send(self(), :router_live_tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "engine"

    socket = assign(socket, :tab, tab)

    socket =
      if tab == "live" do
        assign(socket, :inflight, visible_inflight())
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
    case socket.assigns.config |> Config.changeset(params) |> Repo.update() do
      {:ok, config} ->
        SmartRouter.invalidate()

        audit(socket, "router.config_update", "router_config", config.id, %{
          "changes" => Map.take(params, @config_audit_fields)
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Router configuration saved."))
         |> load_config()
         |> load_use_cases()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:config_form, to_form(changeset, as: :config))
         |> put_flash(:error, gettext("Could not save the router configuration."))}
    end
  end

  def handle_event("seed_presets", _params, socket) do
    %{inserted: inserted, existing: existing} = Presets.ensure_all!()
    SmartRouter.invalidate()

    audit(socket, "router.use_case_seed", "router_use_case", "presets", %{
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
     |> load_use_cases()}
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
         |> assign(:rule_form, to_form(rule_params(rule), as: :rule))}
    end
  end

  def handle_event("cancel_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_open, false)
     |> assign(:rule_editing, nil)
     |> assign(:rule_form, nil)
     |> assign(:rule_errors, [])}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    attrs = normalize_rule(params)

    result =
      case socket.assigns.rule_editing do
        nil ->
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
    snapshot = SmartRouter.snapshot()
    analysis = RequestAnalyzer.analyze(payload)

    case SmartRouter.dry_run(payload, %{}, snapshot: snapshot) do
      {:ok, decision} ->
        {:noreply,
         socket
         |> assign(:dry_form, to_form(params, as: :dry))
         |> assign(:dry_error, nil)
         |> assign(:dry_analysis, analysis)
         |> assign(:dry_result, decision)
         |> assign(:dry_trace, trace_steps(decision, analysis, snapshot.config))
         |> assign(:dry_audit, candidate_audit(snapshot, analysis, decision))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dry_form, to_form(params, as: :dry))
         |> assign(:dry_error, dry_error_message(reason))
         |> assign(:dry_result, nil)
         |> assign(:dry_trace, [])
         |> assign(:dry_audit, nil)
         |> assign(:dry_analysis, analysis)}
    end
  end

  # ---------------------------------------------------------------------------
  # Live monitor
  # ---------------------------------------------------------------------------

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
      {:noreply,
       socket
       |> stream_insert(:router_events, decorate_log(log),
         at: 0,
         limit: @stream_limit
       )
       |> assign(:router_events_count, socket.assigns.router_events_count + 1)
       |> push_pulse(log)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_log, _log}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  defp load_all(socket) do
    socket
    |> load_config()
    |> load_use_cases()
    |> load_rules()
    |> load_model_options()
  end

  defp load_config(socket) do
    config = Config.ensure!()

    socket
    |> assign(:config, config)
    |> assign(:config_form, to_form(config_params(config), as: :config))
    |> assign(:baseline_warning, baseline_warning(config))
  end

  defp load_use_cases(socket) do
    use_cases =
      Repo.all(
        from uc in UseCase,
          order_by: [asc: uc.priority, asc: uc.key],
          preload: [:fallback_model, use_case_models: :target_model]
      )

    assign(socket, :use_cases, use_cases)
  end

  defp load_rules(socket) do
    rules = Repo.all(from r in Rule, order_by: [asc: r.priority, asc: r.name])
    assign(socket, :rules, rules)
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

  defp config_params(config) do
    %{
      "enabled" => config.enabled,
      "policy" => config.policy,
      "decision_timeout_ms" => config.decision_timeout_ms,
      "decision_context_chars" => config.decision_context_chars,
      "fast_path_max_tokens" => config.fast_path_max_tokens,
      "sticky_ttl_seconds" => config.sticky_ttl_seconds,
      "lock_tool_loops" => config.lock_tool_loops,
      "charge_decision_to_subject" => config.charge_decision_to_subject,
      "decision_model_id" => config.decision_model_id || "",
      "default_model_id" => config.default_model_id || "",
      "baseline_model_id" => config.baseline_model_id || ""
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
      "group_ids" => "",
      "service_ids" => "",
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
      "group_ids" => Enum.join(Map.get(conditions, "group_ids", []), ", "),
      "service_ids" => Enum.join(Map.get(conditions, "service_ids", []), ", "),
      "content_regex" => Map.get(conditions, "content_regex", "")
    }
  end

  defp normalize_rule(params) do
    %{
      "name" => params["name"],
      "description" => params["description"],
      "priority" => integer(params["priority"]) || 100,
      "enabled" => truthy?(params["enabled"]),
      "action" => params["action"],
      "target_use_case_keys" => list_field(params["target_use_case_keys"]),
      "match_conditions" => rule_conditions(params)
    }
  end

  # Only the signals the operator filled become conditions: an empty field is
  # "don't care", exactly what the engine treats a missing key as.
  defp rule_conditions(params) do
    [
      {"min_tokens", integer(params["min_tokens"])},
      {"max_tokens", integer(params["max_tokens"])},
      {"has_tools", boolean_condition_value(params["has_tools"])},
      {"has_vision", boolean_condition_value(params["has_vision"])},
      {"has_structured_output", boolean_condition_value(params["has_structured_output"])},
      {"reasoning_effort", blank_to_nil(params["reasoning_effort"])},
      {"agent_types", list_or_nil(params["agent_types"])},
      {"group_ids", list_or_nil(params["group_ids"])},
      {"service_ids", list_or_nil(params["service_ids"])},
      {"content_regex", blank_to_nil(params["content_regex"])}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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
      "max_tokens" => ""
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
  # but `:dom_id` gives the row a stable DOM id that the template can use.
  defp decorate_log(log) do
    log
    |> ensure_map()
    |> Map.put(:dom_id, "router-log-#{Map.get(log, :id) || System.unique_integer([:positive])}")
  end

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

  defp rule_conditions_summary(rule) do
    rule.match_conditions
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{condition_value(value)}" end)
  end

  defp condition_value(value) when is_list(value), do: Enum.join(value, "|")
  defp condition_value(value), do: to_string(value)

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
