defmodule TokengateWeb.RouterLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Logs.Inflight
  alias Tokengate.Providers
  alias Tokengate.Repo

  alias Tokengate.SmartRouter.{
    Config,
    Rule,
    ShadowEvaluation,
    ShadowEvaluator,
    UseCase,
    UseCaseModel,
    Versions
  }

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "router-#{u}@example.com",
        name: "Router #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # El idioma por defecto de la UI es inglés; este archivo fija las etiquetas
    # en español, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp admin_conn(conn) do
    %{user: user, password: password} = register("admin")
    login(conn, user, password)
  end

  # A priced llm model with one active global lane: the snapshot loader needs
  # both to rank a destination (an unpriced lane ranks but cannot be priced).
  defp create_priced_model(name) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(%{name: "Router Prov #{u}", base_url: "http://localhost:1"})

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-#{u}",
        status: "active"
      })

    {:ok, model} =
      Providers.create_model(%{name: name, context_window: 128_000})

    {:ok, _lane} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "#{name}-upstream",
        priority: 1,
        enabled: true,
        pricing_unit: "per_1m_tokens",
        input_cost_per_million: "1.0",
        output_cost_per_million: "2.0"
      })

    model
  end

  defp enable_router do
    Config.ensure!()
    |> Config.changeset(%{"enabled" => true})
    |> Repo.update!()
  end

  defp create_use_case!(attrs) do
    %UseCase{}
    |> UseCase.changeset(
      Map.merge(%{"key" => "test_uc_#{unique()}", "name" => "Test use case"}, attrs)
    )
    |> Repo.insert!()
  end

  defp use_case_params(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "test_uc",
        "name" => "Test use case",
        "description" => "A use case created from the test",
        "tags" => "code, tests",
        "priority" => "10",
        "enabled" => "true",
        "requires_tools" => "false",
        "requires_vision" => "false",
        "requires_structured_output" => "false",
        "critical_accuracy" => "false",
        "allow_downgrade" => "true",
        "pin_session" => "true",
        "keep_last_n_images" => "",
        "max_history_turns" => "",
        "compact_json" => "false",
        "stale_tool_trim_threshold_pct" => "",
        "fallback_model_id" => ""
      },
      overrides
    )
  end

  defp destination_params(model_id, overrides \\ %{}) do
    Map.merge(
      %{
        "target_model_id" => model_id,
        "effort_tier" => "any",
        "effort_override" => "",
        "min_confidence" => "",
        "supports_tools" => "false",
        "supports_vision" => "false",
        "supports_structured_output" => "false",
        "tags" => "fast",
        "flags_json" => "",
        "priority" => "10",
        "enabled" => "true"
      },
      overrides
    )
  end

  defp insert_destination!(use_case_id, model_id, overrides) do
    attrs =
      destination_params(model_id, overrides)
      |> Map.put("router_use_case_id", use_case_id)
      |> Map.put("tags", ["fast"])
      |> Map.put("flags", %{})

    %UseCaseModel{}
    |> UseCaseModel.changeset(attrs)
    |> Repo.insert!()
  end

  ## Access ------------------------------------------------------------------

  test "non-admins are redirected away from the router page", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/catalog/router")
  end

  ## Engine tab --------------------------------------------------------------

  test "the engine tab renders the global config and the use case list", %{conn: conn} do
    {:ok, view, html} = live(admin_conn(conn), ~p"/catalog/router")

    # Locale is es for this file: assert the translated header, not the msgid.
    assert html =~ "Router inteligente"
    assert has_element?(view, "#router-nav")
    assert has_element?(view, "#router-config-card")
    assert has_element?(view, "#router-config-form")
    assert has_element?(view, "#config_enabled")
    assert has_element?(view, "#config_decision_model_id")
    assert has_element?(view, "#config_baseline_model_id")
    # Deterministic mode is the first option of the decision-model picker.
    assert has_element?(
             view,
             "#config_decision_model_id option[value='']",
             "Ninguno (determinista)"
           )

    assert has_element?(view, "#router-use-cases-card")
    assert has_element?(view, "#seed-presets")
    assert has_element?(view, "#router-switch-state", "Desactivado")
  end

  test "linking straight to a tab renders that tab", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, rules, _html} = live(conn, ~p"/catalog/router?tab=rules")
    assert has_element?(rules, "#router-rules-card")
    assert has_element?(rules, "#new-rule")

    {:ok, dry, _html} = live(recycle(conn), ~p"/catalog/router?tab=dry_run")
    assert has_element?(dry, "#dry-run-form")
    assert has_element?(dry, "#run-dry-run")

    {:ok, live_tab, _html} = live(recycle(conn), ~p"/catalog/router?tab=live")
    assert has_element?(live_tab, "#router-pulse")
    assert has_element?(live_tab, "#router-inflight")
    assert has_element?(live_tab, "#router-events")
  end

  test "saving the config enables the router, invalidates and audits", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router")

    view
    |> form("#router-config-form",
      config: %{
        "enabled" => "true",
        "policy" => "cost_first",
        "decision_timeout_ms" => "900",
        "decision_context_chars" => "800",
        "fast_path_max_tokens" => "0",
        "sticky_ttl_seconds" => "600",
        "lock_tool_loops" => "true",
        "charge_decision_to_subject" => "false",
        "decision_model_id" => "",
        "default_model_id" => "",
        "baseline_model_id" => ""
      }
    )
    |> render_submit()

    config = Config.get()
    assert config.enabled
    assert config.policy == "cost_first"
    assert config.decision_timeout_ms == 900
    refute config.charge_decision_to_subject

    assert Repo.exists?(from a in AuditLog, where: a.action == "router.config_update")
    assert has_element?(view, "#router-switch-state", "Activo")
  end

  test "the baseline warning appears when the baseline lane has no price", %{conn: conn} do
    # Un modelo sin model_providers: no hay lane que pueda llevar precio.
    {:ok, model} =
      Providers.create_model(%{name: "baseline-#{unique()}", context_window: 128_000})

    Config.ensure!()
    |> Config.changeset(%{"baseline_model_id" => model.id})
    |> Repo.update!()

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router")

    assert has_element?(view, "#baseline-unpriced-warning")
  end

  test "use cases can be created, edited and toggled", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router")

    render_click(element(view, "#new-use-case"))
    assert has_element?(view, "#use-case-form")

    view
    |> form("#use-case-form", use_case: use_case_params())
    |> render_submit()

    use_case = Repo.get_by!(UseCase, key: "test_uc")
    assert use_case.name == "Test use case"
    assert use_case.tags == ["code", "tests"]
    assert render(view) =~ "Test use case"
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.use_case_create")

    # Invalid submit keeps the modal open with the error list.
    render_click(element(view, "#new-use-case"))

    view
    |> form("#use-case-form", use_case: use_case_params(%{"key" => "Not A Slug"}))
    |> render_submit()

    assert has_element?(view, "#use-case-errors")
    refute Repo.get_by(UseCase, key: "Not A Slug")

    render_click(element(view, "#cancel-use-case"))

    # Toggle flips `enabled` in place.
    render_click(element(view, "#toggle-use-case-#{use_case.id}"))
    refute Repo.get(UseCase, use_case.id).enabled
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.use_case_toggle")
  end

  test "an existing use case can be edited in place", %{conn: conn} do
    use_case =
      create_use_case!(%{
        "name" => "Original name",
        "tags" => ["code"],
        "max_history_turns" => 12,
        "compact_json" => true
      })

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router")

    render_click(element(view, "#edit-use-case-#{use_case.id}"))
    assert has_element?(view, "#use-case-form")

    view
    |> form("#use-case-form",
      use_case:
        use_case_params(%{"key" => use_case.key, "name" => "Renamed", "tags" => "code, docs"})
    )
    |> render_submit()

    updated = Repo.get(UseCase, use_case.id)
    assert updated.name == "Renamed"
    assert updated.tags == ["code", "docs"]
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.use_case_update")
  end

  test "destination CRUD and a dry run over the saved config", %{conn: conn} do
    model = create_priced_model("model-#{unique()}")
    enable_router()
    use_case = create_use_case!(%{})

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/catalog/router")

    render_click(element(view, "#router-uc-destinations-#{use_case.id}"))
    assert has_element?(view, "#router-destinations-#{use_case.id}")

    render_click(element(view, "#new-destination-#{use_case.id}"))
    assert has_element?(view, "#destination-form")

    view
    |> form("#destination-form", destination: destination_params(model.id))
    |> render_submit()

    destination = Repo.get_by!(UseCaseModel, router_use_case_id: use_case.id)
    assert destination.target_model_id == model.id
    assert destination.effort_tier == "any"
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.destination_create")

    # Toggle + delete round-trip.
    render_click(element(view, "#toggle-destination-#{destination.id}"))
    refute Repo.get(UseCaseModel, destination.id).enabled
    render_click(element(view, "#delete-destination-#{destination.id}"))
    refute Repo.get(UseCaseModel, destination.id)

    # Re-create it so the dry run has a destination to land on.
    %UseCaseModel{}
    |> UseCaseModel.changeset(%{
      "router_use_case_id" => use_case.id,
      "target_model_id" => model.id,
      "effort_tier" => "any"
    })
    |> Repo.insert!()

    {:ok, dry, _html} = live(recycle(conn), ~p"/catalog/router?tab=dry_run")

    dry
    |> form("#dry-run-form",
      dry: %{
        "prompt" => "Implement a small function with tests",
        "effort" => "",
        "max_tokens" => "",
        "has_tools" => "false",
        "has_vision" => "false",
        "structured" => "false"
      }
    )
    |> render_submit()

    assert has_element?(dry, "#dry-run-result")
    assert has_element?(dry, "#dry-run-use-case", "Test use case")
    assert has_element?(dry, "#dry-run-primary", model.name)
    assert has_element?(dry, "#dry-run-classifier", "determinista")
    assert has_element?(dry, "#dry-run-discarded")
    assert has_element?(dry, "#dry-run-prompt-policy")
  end

  test "the dry run audits destinations that cannot honour the payload's capabilities",
       %{conn: conn} do
    with_tools = create_priced_model("tools-#{unique()}")
    without_tools = create_priced_model("no-tools-#{unique()}")

    enable_router()
    use_case = create_use_case!(%{})

    insert_destination!(use_case.id, with_tools.id, %{"supports_tools" => "true"})
    insert_destination!(use_case.id, without_tools.id, %{"priority" => "20"})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=dry_run")

    view
    |> form("#dry-run-form",
      dry: %{"prompt" => "call the lookup tool", "has_tools" => "true"}
    )
    |> render_submit()

    assert has_element?(view, "#dry-run-result")
    assert has_element?(view, "#dry-run-eligible", with_tools.name)

    # The use case itself is NOT flagged `requires_tools`: the payload carries
    # tools, so a destination without tool support is still ineligible. The
    # audit must say so instead of advertising it as a live candidate.
    assert has_element?(view, "#dry-run-discarded", without_tools.name)

    assert has_element?(
             view,
             "#dry-run-discarded",
             "el caso de uso requiere soporte de tools"
           )

    refute has_element?(view, "#dry-run-eligible", without_tools.name)
  end

  test "the dry run reports a disabled router instead of pretending", %{conn: conn} do
    Config.ensure!()

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=dry_run")

    view
    |> form("#dry-run-form", dry: %{"prompt" => "hello"})
    |> render_submit()

    assert has_element?(view, "#dry-run-error")
    refute has_element?(view, "#dry-run-result")
  end

  ## Rules tab ---------------------------------------------------------------

  test "rules can be created, toggled and deleted", %{conn: conn} do
    use_case = create_use_case!(%{})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=rules")

    render_click(element(view, "#new-rule"))
    assert has_element?(view, "#rule-form")

    view
    |> form("#rule-form",
      rule: %{
        "name" => "Force tests",
        "description" => "Any request with tools goes to the test use case",
        "priority" => "5",
        "enabled" => "true",
        "action" => "force_use_case",
        "target_use_case_keys" => use_case.key,
        "min_tokens" => "100",
        "max_tokens" => "",
        "has_tools" => "true",
        "has_vision" => "",
        "has_structured_output" => "",
        "reasoning_effort" => "",
        "agent_types" => "claude-code",
        "group_ids" => "",
        "service_ids" => "",
        "content_regex" => ""
      }
    )
    |> render_submit()

    rule = Repo.get_by!(Rule, name: "Force tests")
    assert rule.action == "force_use_case"
    assert rule.target_use_case_keys == [use_case.key]

    assert rule.match_conditions == %{
             "min_tokens" => 100,
             "has_tools" => true,
             "agent_types" => ["claude-code"]
           }

    assert Repo.exists?(from a in AuditLog, where: a.action == "router.rule_create")

    render_click(element(view, "#toggle-rule-#{rule.id}"))
    refute Repo.get(Rule, rule.id).enabled

    render_click(element(view, "#delete-rule-#{rule.id}"))
    refute Repo.get(Rule, rule.id)
  end

  test "an invalid rule keeps the modal open with its errors", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=rules")

    render_click(element(view, "#new-rule"))

    view
    |> form("#rule-form",
      rule: %{
        "name" => "Bad force",
        "action" => "force_use_case",
        "target_use_case_keys" => "a, b",
        "priority" => "10",
        "enabled" => "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#rule-errors")
    refute Repo.get_by(Rule, name: "Bad force")
  end

  ## Live monitor ------------------------------------------------------------

  test "the live tab tracks only routed in-flight requests and completed logs", %{conn: conn} do
    # Registered BEFORE the tab mounts: `visible_inflight/0` is the path here.
    routed =
      Inflight.start_request(%{
        model_requested: "alias-requested",
        model_resolved: "model-inflight",
        routed_via_router: true,
        router_use_case_key: "coding_implement",
        router_effort_tier: "high",
        router_decision_source: "classifier",
        user_email: "live@example.com",
        subject_type: "user",
        provider_name: "Prov Live"
      })

    direct =
      Inflight.start_request(%{
        model_requested: "model-direct",
        user_email: "direct@example.com",
        subject_type: "user"
      })

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=live")

    assert has_element?(view, "#router-inflight-#{routed.id}")
    # The RESOLVED model is what is actually serving: the requested alias must
    # not be shown in its place.
    assert has_element?(view, "#router-inflight-model-#{routed.id}", "model-inflight")
    refute has_element?(view, "#router-inflight-model-#{routed.id}", "alias-requested")
    assert has_element?(view, "#router-inflight-tier-#{routed.id}", "high")
    assert has_element?(view, "#router-inflight-source-#{routed.id}", "classifier")

    # Direct traffic is not this monitor's business (the registry is shared
    # with the global Logs page).
    refute has_element?(view, "#router-inflight-#{direct.id}")

    Inflight.finish_request(direct.id)
    Inflight.finish_request(routed.id)
    refute has_element?(view, "#router-inflight-#{routed.id}")

    # A routed entry that starts AFTER mount goes through handle_info/2, which
    # applies the same filter.
    later = Inflight.start_request(%{model_requested: "late", routed_via_router: true})
    assert has_element?(view, "#router-inflight-#{later.id}")
    Inflight.finish_request(later.id)

    log = %Tokengate.Logs.RequestLog{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      subject_type: "service",
      service: %{name: "Service Live"},
      model_requested: "model-router",
      model_resolved: "model-router",
      status_code: 200,
      prompt_tokens: 100,
      completion_tokens: 50,
      latency_ms: 1_000,
      ttft_ms: 200,
      provider_cost_usd: Decimal.new("0.010000"),
      provider: %{name: "Prov Router"},
      routed_via_router: true,
      router_use_case_key: "coding_implement",
      router_effort_tier: "high",
      router_decision_source: "classifier",
      router_direct_access: false,
      router_decision_cost_usd: Decimal.new("0.001000"),
      router_baseline_cost_usd: Decimal.new("0.020000")
    }

    Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, log})
    html = render(view)

    assert html =~ "Service Live"
    assert html =~ "coding_implement"
    assert html =~ "model-router"
    assert has_element?(view, "#router-live-no-direct-#{log.id}")

    # Non-routed traffic is ignored by this monitor.
    other = %{
      log
      | id: Ecto.UUID.generate(),
        routed_via_router: false,
        model_resolved: "direct-model"
    }

    Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, other})
    refute render(view) =~ "direct-model"

    # The classifier's own billed row is routed, but it is not served traffic:
    # showing it would count the decision twice.
    decision = %{
      log
      | id: Ecto.UUID.generate(),
        request_type: "router_decision",
        model_resolved: "decision-model"
    }

    Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, decision})
    refute render(view) =~ "decision-model"
  end

  ## Versions & shadow ------------------------------------------------------

  defp default_config! do
    Config.ensure!()
    Versions.get_default!()
  end

  defp insert_rule!(config_id, name, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "router_config_id" => config_id,
          "name" => name,
          "description" => "Created by the router live test",
          "action" => "restrict_use_cases",
          "target_use_case_keys" => ["fast"],
          "priority" => 50
        },
        overrides
      )

    %Rule{} |> Rule.changeset(attrs) |> Repo.insert!()
  end

  defp clone_via_ui!(view, name) do
    view |> element("#clone-version-btn") |> render_click()
    assert has_element?(view, "#clone-version-modal")

    view
    |> form("#clone-version-form", clone: %{"name" => name, "description" => "Candidate"})
    |> render_submit()

    Repo.get_by!(Config, name: name)
  end

  defp routed_log(id, model) do
    %Tokengate.Logs.RequestLog{
      id: id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      subject_type: "service",
      service: %{name: "Shadow live service"},
      model_requested: model,
      model_resolved: model,
      status_code: 200,
      prompt_tokens: 100,
      completion_tokens: 50,
      latency_ms: 1_000,
      ttft_ms: 200,
      routed_via_router: true,
      router_use_case_key: "fast",
      router_effort_tier: "low",
      router_decision_source: "classifier"
    }
  end

  defp shadow_eval(log_id, attrs) do
    struct(
      %ShadowEvaluation{
        id: Ecto.UUID.generate(),
        request_log_id: log_id,
        request_inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        shadow_config_id: Ecto.UUID.generate(),
        shadow_config_name: "Shadow B",
        use_case_key: "fast",
        effort_tier: "low",
        model_name: "shadow-model",
        matches_default_model: false,
        matches_default_tier: true
      },
      attrs
    )
  end

  test "cloning a version creates an isolated draft in the switcher and the table", %{
    conn: conn
  } do
    use_case = create_use_case!(%{"name" => "Default use case"})
    default = default_config!()
    rule = insert_rule!(default.id, "Default rule")

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router")
    assert has_element?(view, "#router-version-switcher")
    assert has_element?(view, "#editing-version-name", default.name)

    clone = clone_via_ui!(view, "Candidate A")

    refute clone.is_default
    refute clone.shadow_enabled
    assert is_nil(clone.archived_at)

    # It shows up in the switcher and in the Versions & Shadow table.
    assert has_element?(view, "#router-versions-table")
    assert has_element?(view, "#router-version-row-#{clone.id}")
    assert has_element?(view, "#version-state-#{clone.id}", "Borrador")
    assert has_element?(view, "#router-version-switcher option", "Candidate A")
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.version_clone")

    # The copy owns its own use cases and rules: nothing is shared with the
    # Default, so editing one can never move the other.
    cloned_uc = Repo.get_by!(UseCase, router_config_id: clone.id, key: use_case.key)
    cloned_rule = Repo.get_by!(Rule, router_config_id: clone.id, name: "Default rule")
    refute cloned_uc.id == use_case.id
    refute cloned_rule.id == rule.id
    assert Repo.get(UseCase, use_case.id).router_config_id == default.id

    # Selecting the clone scopes the engine tab to ITS catalogue.
    view |> element("#edit-version-#{clone.id}") |> render_click()
    assert has_element?(view, "#router-uc-row-#{cloned_uc.id}")
    refute has_element?(view, "#router-uc-row-#{use_case.id}")
    assert has_element?(view, "#editing-version-name", "Candidate A")

    # The switcher itself drives the selection.
    view
    |> form("#router-version-switcher", nav: %{"version" => default.id})
    |> render_change()

    assert has_element?(view, "#router-uc-row-#{use_case.id}")
    refute has_element?(view, "#router-uc-row-#{cloned_uc.id}")
  end

  test "a candidate can shadow a sample and the Default cannot", %{conn: conn} do
    default = default_config!()
    candidate = Versions.clone_version!(default.id, %{"name" => "Shadow candidate"})

    {:ok, view, _html} =
      live(admin_conn(conn), ~p"/catalog/router?tab=versions&version=#{candidate.id}")

    assert has_element?(view, "#shadow-form-#{candidate.id}")
    refute has_element?(view, "#shadow-form-#{default.id}")

    view
    |> form(
      "#shadow-form-#{candidate.id}",
      %{"shadow" => %{"shadow_enabled" => "true", "shadow_sample_pct" => "35"}}
    )
    |> render_submit()

    updated = Repo.get(Config, candidate.id)
    assert updated.shadow_enabled
    assert updated.shadow_sample_pct == 35
    assert has_element?(view, "#version-state-#{candidate.id}", "Shadow 35%")
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.version_shadow")

    # Out-of-range samples are rejected instead of silently clamped.
    view
    |> form(
      "#shadow-form-#{candidate.id}",
      %{"shadow" => %{"shadow_enabled" => "true", "shadow_sample_pct" => "150"}}
    )
    |> render_submit()

    assert Repo.get(Config, candidate.id).shadow_sample_pct == 35

    # A non-numeric sample is reported, never applied as "keep the current".
    view
    |> form(
      "#shadow-form-#{candidate.id}",
      %{"shadow" => %{"shadow_enabled" => "true", "shadow_sample_pct" => "soon"}}
    )
    |> render_submit()

    assert Repo.get(Config, candidate.id).shadow_sample_pct == 35

    # The Default cannot shadow itself, even when the event is fired directly.
    render_click(view, "set_shadow", %{
      "id" => default.id,
      "shadow_enabled" => "true",
      "shadow_sample_pct" => "50"
    })

    refute Repo.get(Config, default.id).shadow_enabled
  end

  test "a candidate can be archived and restored from the Versions tab", %{conn: conn} do
    default = default_config!()
    candidate = Versions.clone_version!(default.id, %{"name" => "Archive me"})

    {:ok, view, _html} =
      live(admin_conn(conn), ~p"/catalog/router?tab=versions&version=#{candidate.id}")

    view |> element("#archive-version-#{candidate.id}") |> render_click()

    assert Repo.get!(Config, candidate.id).archived_at
    assert Repo.exists?(from a in AuditLog, where: a.action == "router.version_archive")

    # Archiving the edited version drops the selection back to the Default.
    assert has_element?(view, "#editing-version-name", default.name)

    view |> element("#toggle-archived-versions") |> render_click()
    assert has_element?(view, "#router-version-row-#{candidate.id}")
    assert has_element?(view, "#version-state-#{candidate.id}", "Archivada")
    assert has_element?(view, "#unarchive-version-#{candidate.id}")
    refute has_element?(view, "#promote-version-#{candidate.id}")

    view |> element("#unarchive-version-#{candidate.id}") |> render_click()
    refute Repo.get!(Config, candidate.id).archived_at
  end

  test "a candidate config form never moves the global kill switch or baseline", %{conn: conn} do
    default = default_config!()
    candidate = Versions.clone_version!(default.id, %{"name" => "Global guard"})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?version=#{candidate.id}")

    # The two global knobs render read-only instead of as form inputs.
    assert has_element?(view, "#router-global-kill-switch")
    assert has_element?(view, "#router-global-baseline")
    assert has_element?(view, "#router-global-config-note")
    refute has_element?(view, "#config_enabled")
    refute has_element?(view, "#config_baseline_model_id")

    # Even a hand-crafted payload cannot move them through a candidate.
    render_click(view, "save_config", %{
      "config" => %{
        "enabled" => "true",
        "baseline_model_id" => "",
        "policy" => "latency_first"
      }
    })

    refute Repo.get!(Config, default.id).enabled
    assert Repo.get!(Config, candidate.id).policy == "latency_first"
  end

  test "promoting a version swaps the Default and keeps the globals intact", %{conn: conn} do
    baseline = create_priced_model("baseline-#{unique()}")

    default =
      default_config!()
      |> Config.changeset(%{"enabled" => true, "baseline_model_id" => baseline.id})
      |> Repo.update!()

    audit_count =
      Repo.aggregate(from(a in AuditLog, where: a.action == "router.version_promote"), :count)

    candidate = Versions.clone_version!(default.id, %{"name" => "Promotion candidate"})

    # The candidate disagrees on its own knobs AND on the two global ones.
    candidate
    |> Config.changeset(%{
      "enabled" => false,
      "baseline_model_id" => nil,
      "policy" => "quality_first"
    })
    |> Repo.update!()

    {:ok, view, _html} =
      live(admin_conn(conn), ~p"/catalog/router?tab=versions&version=#{candidate.id}")

    view |> element("#promote-version-#{candidate.id}") |> render_click()
    assert has_element?(view, "#promote-version-modal")

    view |> element("#confirm-promote-version") |> render_click()

    promoted = Repo.get!(Config, candidate.id)
    assert promoted.is_default
    refute promoted.shadow_enabled
    # Global policy travelled with the promotion instead of from the candidate.
    assert promoted.enabled
    assert promoted.baseline_model_id == baseline.id
    # Version content stayed the candidate's own.
    assert promoted.policy == "quality_first"

    outgoing = Repo.get!(Config, default.id)
    refute outgoing.is_default

    assert Repo.aggregate(
             from(a in AuditLog, where: a.action == "router.version_promote"),
             :count
           ) == audit_count + 1
  end

  test "the diff modal reports real differences against the Default", %{conn: conn} do
    use_case = create_use_case!(%{"name" => "Original name"})
    default = default_config!()
    candidate = Versions.clone_version!(default.id, %{"name" => "Diff candidate"})

    cloned_uc = Repo.get_by!(UseCase, router_config_id: candidate.id, key: use_case.key)
    cloned_uc |> UseCase.changeset(%{"name" => "Renamed in candidate"}) |> Repo.update!()

    candidate
    |> Config.changeset(%{"policy" => "quality_first", "fast_path_max_tokens" => 1234})
    |> Repo.update!()

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?version=#{candidate.id}")

    assert has_element?(view, "#diff-version-btn")
    view |> element("#diff-version-btn") |> render_click()

    assert has_element?(view, "#diff-version-modal")
    assert has_element?(view, "#diff-config-policy", "quality_first")
    assert has_element?(view, "#diff-config-fast_path_max_tokens", "1234")
    assert has_element?(view, "#diff-use-case-#{use_case.key}", "Renamed in candidate")
    refute has_element?(view, "#diff-rule-anything")
  end

  test "rule match pickers search users, services and limit profiles by name", %{conn: conn} do
    use_case = create_use_case!(%{})
    {:ok, group} = Accounts.create_group(%{"name" => "Premium profile #{unique()}"})
    {:ok, service} = Accounts.create_service(%{"name" => "searchable-service-#{unique()}"})
    %{user: target} = register("user")

    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=rules")

    render_click(element(view, "#new-rule"))
    assert has_element?(view, "#rule-form")

    # Limit profile -----------------------------------------------------
    view
    |> element("#rule-group-search")
    |> render_change(%{"rule_group_search" => group.name})

    assert has_element?(view, "#rule-group-results")
    assert has_element?(view, "#rule-group-option-#{group.id}", group.name)
    view |> element("#rule-group-option-#{group.id}") |> render_click()
    assert has_element?(view, "#rule-group-chips", group.name)

    # Service -----------------------------------------------------------
    view
    |> element("#rule-service-search")
    |> render_change(%{"rule_service_search" => service.name})

    assert has_element?(view, "#rule-service-option-#{service.id}", service.name)
    view |> element("#rule-service-option-#{service.id}") |> render_click()
    assert has_element?(view, "#rule-service-chips", service.name)

    # User --------------------------------------------------------------
    view
    |> element("#rule-user-search")
    |> render_change(%{"rule_user_search" => target.name})

    assert has_element?(view, "#rule-user-option-#{target.id}", target.name)
    view |> element("#rule-user-option-#{target.id}") |> render_click()
    assert has_element?(view, "#rule-user-chips", target.name)

    view
    |> form("#rule-form",
      rule: %{
        "name" => "Scoped rule",
        "action" => "restrict_use_cases",
        "target_use_case_keys" => use_case.key,
        "priority" => "7",
        "enabled" => "true"
      }
    )
    |> render_submit()

    rule = Repo.get_by!(Rule, name: "Scoped rule")
    assert rule.match_conditions["group_ids"] == [group.id]
    assert rule.match_conditions["service_ids"] == [service.id]
    assert rule.match_conditions["user_ids"] == [target.id]

    # The table resolves names instead of dumping raw uuids.
    assert has_element?(view, "#router-rule-row-#{rule.id}", group.name)
    assert has_element?(view, "#router-rule-row-#{rule.id}", service.name)
    assert has_element?(view, "#router-rule-row-#{rule.id}", target.name)

    # Editing repopulates the chips, and a chip can be removed again.
    render_click(element(view, "#edit-rule-#{rule.id}"))
    assert has_element?(view, "#rule-user-chips", target.name)

    view |> element("#remove-rule-user-#{target.id}") |> render_click()
    refute has_element?(view, "#rule-user-chips")
  end

  test "the dry run compares a candidate version against the Default", %{conn: conn} do
    model_a = create_priced_model("cand-a-#{unique()}")
    model_b = create_priced_model("cand-b-#{unique()}")

    enable_router()
    use_case = create_use_case!(%{})
    insert_destination!(use_case.id, model_a.id, %{})

    default = default_config!()
    candidate = Versions.clone_version!(default.id, %{"name" => "Dry candidate"})

    cloned_uc = Repo.get_by!(UseCase, router_config_id: candidate.id, key: use_case.key)

    [cloned_destination] =
      Repo.all(from d in UseCaseModel, where: d.router_use_case_id == ^cloned_uc.id)

    cloned_destination
    |> UseCaseModel.changeset(%{"target_model_id" => model_b.id})
    |> Repo.update!()

    {:ok, view, _html} =
      live(admin_conn(conn), ~p"/catalog/router?tab=dry_run&version=#{candidate.id}")

    assert has_element?(view, "#dry-run-version", "Dry candidate")

    view
    |> form("#dry-run-form",
      dry: %{"prompt" => "Implement a small function", "has_tools" => "false"}
    )
    |> render_submit()

    assert has_element?(view, "#dry-run-result")
    assert has_element?(view, "#dry-run-comparison")
    assert has_element?(view, "#dry-run-comparison-default-name", default.name)
    assert has_element?(view, "#dry-run-comparison-version-name", "Dry candidate")
    # The Default still runs its own destination; the candidate its own.
    assert has_element?(view, "#dry-run-comparison-model", model_a.name)
    assert has_element?(view, "#dry-run-comparison-model", model_b.name)
    assert has_element?(view, "#dry-run-comparison-use-case", use_case.key)
    assert has_element?(view, "#dry-run-comparison-model", "distinto")
  end

  test "the live tab shows shadow evaluations and filters discrepancies", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=live")

    disagreeing = routed_log(Ecto.UUID.generate(), "default-model")
    Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, disagreeing})
    assert render(view) =~ "Shadow live service"

    eval = shadow_eval(disagreeing.id, %{})

    Phoenix.PubSub.broadcast(
      Tokengate.PubSub,
      ShadowEvaluator.topic(),
      {:shadow_evaluated, disagreeing.id, [eval]}
    )

    assert has_element?(view, "#router-shadows-#{disagreeing.id}")

    assert has_element?(
             view,
             "#router-shadow-#{disagreeing.id}-#{eval.shadow_config_id}",
             "Shadow B"
           )

    assert has_element?(
             view,
             "#router-shadow-#{disagreeing.id}-#{eval.shadow_config_id}",
             "shadow-model"
           )

    assert has_element?(
             view,
             "#router-shadow-#{disagreeing.id}-#{eval.shadow_config_id}",
             "modelo distinto"
           )

    agreeing = routed_log(Ecto.UUID.generate(), "agree-model")
    Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, agreeing})

    agreed_eval =
      shadow_eval(agreeing.id, %{model_name: "agree-model", matches_default_model: true})

    Phoenix.PubSub.broadcast(
      Tokengate.PubSub,
      ShadowEvaluator.topic(),
      {:shadow_evaluated, agreeing.id, [agreed_eval]}
    )

    assert has_element?(
             view,
             "#router-shadow-#{agreeing.id}-#{agreed_eval.shadow_config_id}",
             "= igual"
           )

    # The discrepancy filter keeps only the request the candidate would have
    # routed differently.
    view |> element("#live-filter-discrepancies") |> render_click()

    assert has_element?(view, "#router-shadows-#{disagreeing.id}")
    refute has_element?(view, "#router-shadows-#{agreeing.id}")

    view |> element("#live-filter-all") |> render_click()
    assert has_element?(view, "#router-shadows-#{agreeing.id}")

    # Leaving and re-entering the tab keeps the evaluations and re-hydrates the
    # map from the recorded rows (a no-op here, but the query must run clean).
    view |> element("#router-tab-engine") |> render_click()
    view |> element("#router-tab-live") |> render_click()

    assert has_element?(view, "#router-shadows-#{disagreeing.id}")
    assert has_element?(view, "#router-shadows-#{agreeing.id}")
  end

  test "a verdict that only now makes a row visible clears the empty state", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=live")

    view |> element("#live-filter-discrepancies") |> render_click()
    assert has_element?(view, "#router-events-card", "Esperando la próxima request ruteada…")

    log = routed_log(Ecto.UUID.generate(), "default-model")
    send(view.pid, {:new_log, log})
    _ = :sys.get_state(view.pid)

    # Without a verdict the row is hidden by the filter: the empty state stays.
    refute has_element?(view, "#router-events", "default-model")

    send(view.pid, {:shadow_evaluated, log.id, [shadow_eval(log.id, %{})]})

    assert has_element?(view, "#router-shadows-#{log.id}")
    # A real row is on screen now: the "waiting" line must not sit above it.
    refute has_element?(view, "#router-events-card", "Esperando la próxima request ruteada…")
  end

  test "the shadow map and the routed window stay bounded to the same rows", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/router?tab=live")

    for _ <- 1..105 do
      id = Ecto.UUID.generate()
      send(view.pid, {:new_log, routed_log(id, "bounded-model")})
      send(view.pid, {:shadow_evaluated, id, [shadow_eval(id, %{})]})
    end

    state = :sys.get_state(view.pid).socket.assigns
    window = Enum.map(state.recent_refs, &elem(&1, 0))

    assert length(window) == 100
    assert map_size(state.recent_logs) == 100
    # No evaluation outlives the row it describes.
    assert Enum.sort(Map.keys(state.shadows_by_log_id)) == Enum.sort(window)

    # The counter tracks the rows on screen, not every event ever seen.
    assert state.router_events_count == 100
  end
end
