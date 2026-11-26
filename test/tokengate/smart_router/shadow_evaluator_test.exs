defmodule Tokengate.SmartRouter.ShadowEvaluatorTest do
  @moduledoc """
  The Shadow engine: version-scoped snapshots, `DecisionCache` isolation by
  `config_id`, deterministic sampling, real-token pricing and the guarantee
  that a shadow never mutates serving state.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers
  alias Tokengate.Proxy.PromptOptimizer
  alias Tokengate.SmartRouter

  alias Tokengate.SmartRouter.{
    Config,
    DecisionCache,
    Rule,
    SessionPin,
    ShadowEvaluation,
    ShadowEvaluator,
    UseCase,
    UseCaseModel
  }

  alias Tokengate.SmartRouterFixtures, as: Fixtures

  setup do
    DecisionCache.clear_all()
    SessionPin.clear_all()
    SmartRouter.invalidate()
    :ok
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  # A model with ONE global lane, so `Router.primary_tariff/2` can price it.
  defp create_model(prices) do
    n = unique()

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Shadow P #{n}",
        base_url: "https://shadow-#{n}.example.com/v1"
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "Shadow Key #{n}",
        api_key_encrypted: "sk-shadow-#{n}",
        status: "active"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: "shadow-model-#{n}",
        model_type: "llm",
        context_window: 128_000
      })

    {:ok, _lane} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "upstream/shadow-#{n}",
        priority: 1,
        enabled: true,
        input_cost_per_million: Decimal.new(prices.input),
        output_cost_per_million: Decimal.new(prices.output)
      })

    model
  end

  defp member_fixture do
    n = unique()

    {:ok, group} =
      Accounts.create_group(%{
        name: "Shadow Group #{n}",
        default_rpm_limit: 600,
        default_concurrency_limit: 10,
        router_enabled: true,
        unlimited_spend: true
      })

    {:ok, user} =
      Accounts.register_user(%{
        email: "shadow-#{n}@example.com",
        name: "Shadow #{n}",
        password: "password-#{n}-secret1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id, router_enabled: true})

    Repo.preload(member, :group)
  end

  defp enable_default(attrs \\ %{}) do
    config =
      Config.ensure!()
      |> Config.changeset(Map.merge(%{enabled: true}, attrs))
      |> Repo.update!()

    SmartRouter.invalidate()
    config
  end

  # A non-serving version. `attrs` carries the shadow flags.
  defp create_version(attrs) do
    {:ok, version} =
      %Config{}
      |> Config.changeset(Map.merge(%{name: "Version #{unique()}"}, attrs))
      |> Repo.insert()

    SmartRouter.invalidate()
    version
  end

  defp create_use_case(config_id, key, bindings, extra \\ %{}) do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(
        Map.merge(
          %{
            router_config_id: config_id,
            key: key,
            name: "Use case #{key}",
            pin_session: true,
            enabled: true,
            priority: 10
          },
          extra
        )
      )
      |> Repo.insert()

    for binding <- bindings do
      {:ok, _row} =
        %UseCaseModel{}
        |> UseCaseModel.changeset(Map.put(binding, :router_use_case_id, use_case.id))
        |> Repo.insert()
    end

    SmartRouter.invalidate()
    use_case
  end

  defp create_rule(config_id, name) do
    {:ok, rule} =
      %Rule{}
      |> Rule.changeset(%{
        router_config_id: config_id,
        name: name,
        action: "restrict_use_cases",
        target_use_case_keys: ["coding"]
      })
      |> Repo.insert()

    SmartRouter.invalidate()
    rule
  end

  defp payload(text) do
    %{
      "model" => "router",
      "messages" => [%{"role" => "user", "content" => text}]
    }
  end

  defp usage do
    %{
      prompt_tokens: 1_000,
      completion_tokens: 500,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  defp eval_params(context, overrides \\ %{}) do
    Map.merge(
      %{
        request_log_id: Ecto.UUID.generate(),
        request_inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        payload: payload("what does the shadow decide?"),
        context: context,
        default_decision: nil,
        usage: usage(),
        default_served_cost_usd: Decimal.new("0.004"),
        prompt_tokens_saved_est: 0,
        group_member: nil
      },
      overrides
    )
  end

  defp shadow_rows(request_log_id) do
    Repo.all(
      from e in ShadowEvaluation,
        where: e.request_log_id == ^request_log_id,
        order_by: e.inserted_at
    )
  end

  ## DecisionCache isolation ###################################################

  test "DecisionCache fingerprints are scoped by config_id" do
    refute DecisionCache.fingerprint({:question}, "v1") ==
             DecisionCache.fingerprint({:question}, "v2")

    assert DecisionCache.fingerprint({:question}, "v1") ==
             DecisionCache.fingerprint({:question}, "v1")
  end

  test "two versions never share a cached classifier answer" do
    text = "isolate the classifier cache #{unique()}"
    counter = :counters.new(1, [])

    classifier = fn _model, _analysis, _use_cases ->
      :counters.add(counter, 1, 1)
      {:ok, Fixtures.classifier_answer("coding")}
    end

    coding =
      Fixtures.use_case("coding")
      |> Fixtures.with_candidates([Fixtures.candidate("coding", "a", "low")])

    chat =
      Fixtures.use_case("chat")
      |> Fixtures.with_candidates([Fixtures.candidate("chat", "b", "low")])

    snapshot = fn config_id ->
      Fixtures.snapshot([coding, chat], %{
        config: Fixtures.config(%{id: config_id, decision_model_id: "model-decider"}),
        decision_model: Fixtures.decision_model()
      })
    end

    opts = [classifier_fun: classifier]
    request = Fixtures.payload(text)

    assert {:ok, first} = SmartRouter.decide(request, %{}, opts ++ [snapshot: snapshot.("v1")])
    assert first.decision_meta.source == "classifier"
    assert first.decision_meta.config_id == "v1"
    assert :counters.get(counter, 1) == 1

    # Same version, same question -> the cached answer, no second call.
    assert {:ok, cached} = SmartRouter.decide(request, %{}, opts ++ [snapshot: snapshot.("v1")])
    assert cached.decision_meta.source == "decision_cache"
    assert :counters.get(counter, 1) == 1

    # Another version asking the SAME question must ask the classifier again.
    assert {:ok, other} = SmartRouter.decide(request, %{}, opts ++ [snapshot: snapshot.("v2")])
    assert other.decision_meta.source == "classifier"
    assert other.decision_meta.config_id == "v2"
    assert :counters.get(counter, 1) == 2
  end

  ## Version-scoped snapshots ##################################################

  test "snapshot/1 loads ONLY the use cases and rules of its own version" do
    default = enable_default()
    primary = create_model(%{input: "1", output: "2"})

    create_use_case(default.id, "coding", [
      %{target_model_id: primary.id, effort_tier: "high"}
    ])

    create_rule(default.id, "default only rule")

    version = create_version(%{enabled: true})
    other = create_model(%{input: "1", output: "1"})

    create_use_case(version.id, "fast", [
      %{target_model_id: other.id, effort_tier: "low"}
    ])

    create_rule(version.id, "version only rule")

    default_snapshot = SmartRouter.snapshot()
    version_snapshot = SmartRouter.snapshot(config_id: version.id)

    assert default_snapshot.config.id == default.id
    assert Enum.map(default_snapshot.use_cases, & &1.key) == ["coding"]
    assert Enum.map(default_snapshot.rules, & &1.name) == ["default only rule"]

    assert version_snapshot.config.id == version.id
    assert Enum.map(version_snapshot.use_cases, & &1.key) == ["fast"]
    assert Enum.map(version_snapshot.rules, & &1.name) == ["version only rule"]

    # The binding of the Default's use case never leaks into the version's
    # catalogue (and vice versa).
    assert [candidate] = hd(version_snapshot.use_cases).candidates
    assert candidate.model_id == other.id

    # An unknown version is an EMPTY catalogue, never the Default's.
    empty = SmartRouter.snapshot(config_id: Ecto.UUID.generate())
    assert empty.config == nil
    assert empty.use_cases == []
    assert empty.rules == []
  end

  ## Shadow evaluation #########################################################

  test "prices the shadow destination with the REAL tokens and flags the mismatch" do
    member = member_fixture()
    default = enable_default()

    default_model = create_model(%{input: "3", output: "6"})
    shadow_model = create_model(%{input: "1", output: "2"})

    create_use_case(default.id, "coding", [
      %{target_model_id: default_model.id, effort_tier: "high"}
    ])

    version =
      create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    create_use_case(version.id, "coding", [
      %{target_model_id: shadow_model.id, effort_tier: "low"}
    ])

    context = %{subject_id: member.user_id, user_id: member.user_id, session_id: "session-1"}
    request = payload("price the shadow")

    {:ok, default_decision} = SmartRouter.dry_run(request, context)

    assert default_decision.primary.model_id == default_model.id
    assert default_decision.primary.effort_tier == "high"

    params =
      eval_params(context, %{
        payload: request,
        default_decision: default_decision,
        group_member: member,
        request_log_id: Ecto.UUID.generate()
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)

    assert [evaluation] = shadow_rows(params.request_log_id)

    assert evaluation.shadow_config_id == version.id
    assert evaluation.shadow_config_name == version.name
    assert evaluation.default_config_id == default.id

    # The Default's side is what it really decided and really booked.
    assert evaluation.default_use_case_key == "coding"
    assert evaluation.default_model_id == default_model.id
    assert evaluation.default_effort_tier == "high"
    assert Decimal.equal?(evaluation.default_served_cost_usd, Decimal.new("0.004"))

    # The Shadow's side: its own destination, priced over the same tokens.
    assert evaluation.use_case_key == "coding"
    assert evaluation.model_id == shadow_model.id
    assert evaluation.effort_tier == "low"

    # 1_000 prompt * 1/1M + 500 completion * 2/1M = 0.002
    assert Decimal.equal?(evaluation.estimated_served_cost_usd, Decimal.new("0.002"))
    assert evaluation.prompt_tokens_saved_est == 0

    assert evaluation.matches_default_model == false
    assert evaluation.matches_default_tier == false
    # A deterministic layer never reports a classifier price.
    assert evaluation.decision_cost_usd == nil
    assert evaluation.decision_source in ["single_candidate", "fast_path"]
  end

  # A conversation whose tail survives `window_history(messages, 1)`: the old
  # user turn is what a `max_history_turns: 1` policy trims, so the saving is
  # real and measurable by the same estimator the serving path uses.
  defp history_payload do
    %{
      "model" => "router",
      "messages" => [
        %{"role" => "user", "content" => String.duplicate("older turn ", 600)},
        %{"role" => "assistant", "content" => "an answer"},
        %{"role" => "user", "content" => "latest turn"}
      ]
    }
  end

  defp expected_cost(prompt_tokens, completion_tokens, input_rate, output_rate) do
    Decimal.div(
      Decimal.add(
        Decimal.mult(Decimal.new(prompt_tokens), Decimal.new(input_rate)),
        Decimal.mult(Decimal.new(completion_tokens), Decimal.new(output_rate))
      ),
      Decimal.new(1_000_000)
    )
  end

  test "reconstructs the raw prompt and never discounts the Default's trim twice" do
    member = member_fixture()
    default = enable_default()
    same_model = create_model(%{input: "3", output: "6"})

    create_use_case(default.id, "coding", [
      %{target_model_id: same_model.id, effort_tier: "high"}
    ])

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    # Same destination, same tier and NO trimming policy on the Shadow.
    create_use_case(version.id, "coding", [
      %{target_model_id: same_model.id, effort_tier: "high"}
    ])

    context = %{subject_id: member.user_id, session_id: "session-2"}
    {:ok, default_decision} = SmartRouter.dry_run(payload("saved tokens"), context)

    # The provider counted 1_000 prompt tokens AFTER the Default trimmed 400:
    # the raw prompt was 1_400, and this version trims nothing of its own.
    trimmed =
      eval_params(context, %{
        payload: payload("saved tokens"),
        default_decision: default_decision,
        group_member: member,
        prompt_tokens_saved_est: 400
      })

    assert :ok = ShadowEvaluator.evaluate_sync(trimmed)
    assert [evaluation] = shadow_rows(trimmed.request_log_id)

    assert evaluation.prompt_tokens_saved_est == 0
    # 1_400 * 3/1M + 500 * 6/1M = 0.0072. The old maths charged 0.0048
    # (1_000 - 400) — the Default's trim subtracted a second time.
    assert Decimal.equal?(evaluation.estimated_served_cost_usd, expected_cost(1_400, 500, 3, 6))

    # Same model and tier as the Default on this one.
    assert evaluation.matches_default_model == true
    assert evaluation.matches_default_tier == true
  end

  test "a Shadow with the SAME policy as the Default saves its own measured trim, once" do
    member = member_fixture()
    default = enable_default()
    same_model = create_model(%{input: "3", output: "6"})

    create_use_case(
      default.id,
      "coding",
      [%{target_model_id: same_model.id, effort_tier: "high"}],
      %{max_history_turns: 1}
    )

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    create_use_case(
      version.id,
      "coding",
      [%{target_model_id: same_model.id, effort_tier: "high"}],
      %{max_history_turns: 1}
    )

    request = history_payload()
    context = %{subject_id: member.user_id, session_id: "session-same-policy"}
    {:ok, default_decision} = SmartRouter.dry_run(request, context)

    # The trim the policy produces on the RAW payload — the same measurement
    # the evaluator must make for the Shadow side.
    {:ok, shadow_decision} = SmartRouter.dry_run(request, context, config_id: version.id)

    {_optimized, shadow_saved} =
      PromptOptimizer.apply_router_policy(request, shadow_decision.prompt_policy)

    assert is_integer(shadow_saved) and shadow_saved > 0

    params =
      eval_params(context, %{
        payload: request,
        default_decision: default_decision,
        group_member: member,
        # The Default applied the very same policy: the provider only counted
        # 1_000 of the 1_400 raw tokens.
        prompt_tokens_saved_est: 400
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [evaluation] = shadow_rows(params.request_log_id)

    assert evaluation.prompt_tokens_saved_est == shadow_saved

    # 1_400 - shadow_saved, NOT 1_000 - 400 - shadow_saved.
    prompt = max(1_400 - shadow_saved, 0)
    expected = expected_cost(prompt, 500, 3, 6)
    refute Decimal.equal?(expected, expected_cost(prompt - 800, 500, 3, 6))

    assert_in_delta Decimal.to_float(expected),
                    Decimal.to_float(evaluation.estimated_served_cost_usd),
                    0.000001
  end

  test "a Shadow with a DIFFERENT policy gets its own trim, not the Default's" do
    member = member_fixture()
    default = enable_default()
    same_model = create_model(%{input: "3", output: "6"})

    # The Default trims the window...
    create_use_case(
      default.id,
      "coding",
      [%{target_model_id: same_model.id, effort_tier: "high"}],
      %{max_history_turns: 1}
    )

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    # ...the Shadow declares nothing, so it would have sent the raw prompt.
    create_use_case(version.id, "coding", [
      %{target_model_id: same_model.id, effort_tier: "high"}
    ])

    request = history_payload()
    context = %{subject_id: member.user_id, session_id: "session-diff-policy"}
    {:ok, default_decision} = SmartRouter.dry_run(request, context)

    params =
      eval_params(context, %{
        payload: request,
        default_decision: default_decision,
        group_member: member,
        prompt_tokens_saved_est: 400
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [evaluation] = shadow_rows(params.request_log_id)

    # Copying the Default's saving onto this version is exactly the bug: it
    # would report 400 saved tokens and price 1_000 - 400.
    assert evaluation.prompt_tokens_saved_est == 0
    assert Decimal.equal?(evaluation.estimated_served_cost_usd, expected_cost(1_400, 500, 3, 6))
  end

  test "the Shadow's own trim floors the prompt at zero" do
    member = member_fixture()
    default = enable_default()
    same_model = create_model(%{input: "3", output: "6"})

    create_use_case(default.id, "coding", [
      %{target_model_id: same_model.id, effort_tier: "high"}
    ])

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    create_use_case(
      version.id,
      "coding",
      [%{target_model_id: same_model.id, effort_tier: "high"}],
      %{max_history_turns: 1}
    )

    request = history_payload()
    context = %{subject_id: member.user_id, session_id: "session-floor"}
    {:ok, default_decision} = SmartRouter.dry_run(request, context)

    {:ok, shadow_decision} = SmartRouter.dry_run(request, context, config_id: version.id)

    {_optimized, shadow_saved} =
      PromptOptimizer.apply_router_policy(request, shadow_decision.prompt_policy)

    # The Shadow would have cut MORE than the provider counted (the Default
    # trimmed nothing here): the prompt floors at 0, never negative.
    assert shadow_saved > 1_000

    params =
      eval_params(context, %{
        payload: request,
        default_decision: default_decision,
        group_member: member,
        prompt_tokens_saved_est: 0
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [evaluation] = shadow_rows(params.request_log_id)

    assert evaluation.prompt_tokens_saved_est == shadow_saved
    # 0 prompt + 500 * 6/1M = 0.003
    assert Decimal.equal?(evaluation.estimated_served_cost_usd, expected_cost(0, 500, 3, 6))
  end

  test "sampling is deterministic on the sticky key" do
    member = member_fixture()
    default = enable_default()
    model = create_model(%{input: "1", output: "1"})

    create_use_case(default.id, "coding", [%{target_model_id: model.id, effort_tier: "high"}])

    # 1% sample: only the sticky keys hashing to 0 are evaluated.
    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 1})

    create_use_case(version.id, "coding", [%{target_model_id: model.id, effort_tier: "high"}])

    {:ok, default_decision} = SmartRouter.dry_run(payload("sample me"), %{})

    included = sample_key(version.id, 0)
    excluded = sample_key(version.id, 1)

    assert :ok =
             ShadowEvaluator.evaluate_sync(
               eval_params(%{session_id: excluded}, %{
                 payload: payload("sample me"),
                 default_decision: default_decision,
                 group_member: member
               })
             )

    assert Repo.aggregate(ShadowEvaluation, :count) == 0

    params =
      eval_params(%{session_id: included}, %{
        payload: payload("sample me"),
        default_decision: default_decision,
        group_member: member
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [_] = shadow_rows(params.request_log_id)

    # Deterministic: the SAME session on a later turn is sampled the same way.
    again =
      eval_params(%{session_id: included}, %{
        payload: payload("sample me"),
        default_decision: default_decision,
        group_member: member
      })

    assert :ok = ShadowEvaluator.evaluate_sync(again)
    assert [_] = shadow_rows(again.request_log_id)
  end

  test "never touches SessionPin, Budgets or request_logs" do
    member = member_fixture()
    default = enable_default()
    default_model = create_model(%{input: "3", output: "6"})
    shadow_model = create_model(%{input: "1", output: "1"})

    create_use_case(default.id, "coding", [
      %{target_model_id: default_model.id, effort_tier: "high"}
    ])

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    create_use_case(version.id, "coding", [
      %{target_model_id: shadow_model.id, effort_tier: "low"}
    ])

    subject = member.user_id
    session_key = "session-untouched"

    pin = %{
      use_case_id: "pin-use-case",
      use_case_key: "coding",
      use_case_model_id: "pin-binding",
      model_id: default_model.id,
      model_name: default_model.name,
      effort_tier: "high",
      requirements: %{tools: false, vision: false, structured: false}
    }

    assert :ok = SessionPin.put(subject, session_key, pin, 900_000)
    {:ok, default_decision} = SmartRouter.dry_run(payload("shadow me"), %{subject_id: subject})

    spend_before = Budgets.limit_spend({:user, subject})
    logs_before = Repo.aggregate(RequestLog, :count)

    params =
      eval_params(%{subject_id: subject, session_id: session_key}, %{
        payload: payload("shadow me"),
        default_decision: default_decision,
        group_member: member
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [_] = shadow_rows(params.request_log_id)

    # The pin the serving Default owns is untouched, and the shadow wrote none.
    assert SessionPin.get(subject, session_key) == pin
    assert Budgets.limit_spend({:user, subject}) == spend_before
    assert Repo.aggregate(RequestLog, :count) == logs_before
  end

  test "evaluate_async/1 spawns nothing when no version is a shadow" do
    default = enable_default()
    model = create_model(%{input: "1", output: "1"})
    create_use_case(default.id, "coding", [%{target_model_id: model.id, effort_tier: "high"}])

    assert SmartRouter.shadow_configs() == []

    params = eval_params(%{session_id: "no-shadow"})

    assert :ok = ShadowEvaluator.evaluate_async(params)
    assert shadow_rows(params.request_log_id) == []
  end

  test "shadow_configs/0 lists only live, non-default versions" do
    _default = enable_default()
    model = create_model(%{input: "1", output: "1"})

    live = create_version(%{enabled: true, shadow_enabled: true})
    _draft = create_version(%{enabled: true})
    archived = create_version(%{enabled: true, shadow_enabled: true})
    archived |> Config.changeset(%{archived_at: DateTime.utc_now()}) |> Repo.update!()

    create_use_case(live.id, "coding", [%{target_model_id: model.id, effort_tier: "high"}])
    SmartRouter.invalidate()

    assert Enum.map(SmartRouter.shadow_configs(), & &1.id) == [live.id]
    assert archived.id != live.id
  end

  ## Sampling helper ###########################################################

  # A sticky key whose hash lands on one side of a 100-bucket split, so the
  # assertion never depends on luck.
  defp sample_key(config_id, side) do
    found =
      Enum.find(1..5_000, fn n ->
        key = "sample-#{n}"

        case :erlang.phash2({config_id, key}, 100) do
          0 -> side == 0
          _other -> side == 1
        end
      end)

    if is_nil(found), do: raise("no sample key on side #{side} for #{config_id}")
    "sample-#{found}"
  end

  ## Unused-model guard ########################################################

  test "a shadow version whose model has no tariff records no estimated cost" do
    member = member_fixture()
    default = enable_default()
    default_model = create_model(%{input: "3", output: "6"})

    {:ok, bare_model} =
      Providers.create_model(%{
        name: "shadow-no-lane-#{unique()}",
        model_type: "llm",
        context_window: 128_000
      })

    create_use_case(default.id, "coding", [
      %{target_model_id: default_model.id, effort_tier: "high"}
    ])

    version = create_version(%{enabled: true, shadow_enabled: true, shadow_sample_pct: 100})

    create_use_case(version.id, "coding", [
      %{target_model_id: bare_model.id, effort_tier: "low"}
    ])

    context = %{subject_id: member.user_id, session_id: "no-tariff"}
    {:ok, default_decision} = SmartRouter.dry_run(payload("no tariff"), context)

    params =
      eval_params(context, %{
        payload: payload("no tariff"),
        default_decision: default_decision,
        group_member: member
      })

    assert :ok = ShadowEvaluator.evaluate_sync(params)
    assert [evaluation] = shadow_rows(params.request_log_id)
    assert evaluation.model_id == bare_model.id
    # No lane, no tariff: an estimated cost is never invented.
    assert evaluation.estimated_served_cost_usd == nil
  end
end
