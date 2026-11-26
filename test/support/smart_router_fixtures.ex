defmodule Tokengate.SmartRouterFixtures do
  @moduledoc """
  Snapshot builders for the SmartRouter engine tests.

  The engine is database-free by design (`snapshot` in, decision out), so these
  helpers build the exact maps the loader produces without touching Postgres.
  """

  def config(overrides \\ %{}) do
    Map.merge(
      %{
        enabled: true,
        policy: "balanced",
        decision_timeout_ms: 800,
        decision_context_chars: 1_200,
        fast_path_max_tokens: 0,
        sticky_ttl_seconds: 900,
        lock_tool_loops: true,
        charge_decision_to_subject: true,
        decision_model_id: nil,
        default_model_id: nil,
        baseline_model_id: nil
      },
      overrides
    )
  end

  def use_case(key, overrides \\ %{}) do
    Map.merge(
      %{
        id: "uc-#{key}",
        key: key,
        name: String.capitalize(key),
        description: "#{key} work",
        tags: [key],
        requires_tools: false,
        requires_vision: false,
        requires_structured_output: false,
        critical_accuracy: false,
        allow_downgrade: true,
        pin_session: true,
        keep_last_n_images: nil,
        max_history_turns: 20,
        compact_json: false,
        stale_tool_trim_threshold_pct: nil,
        priority: 10,
        enabled: true,
        fallback_model_id: nil,
        candidates: []
      },
      overrides
    )
  end

  def with_candidates(use_case, candidates) do
    Map.put(use_case, :candidates, candidates)
  end

  def candidate(use_case_key, model_name, tier, overrides \\ %{}) do
    lane_overrides = Map.get(overrides, :lane, %{})

    Map.merge(
      %{
        id: "bind-#{use_case_key}-#{model_name}-#{tier}",
        use_case_id: "uc-#{use_case_key}",
        use_case_key: use_case_key,
        model_id: "model-#{model_name}",
        model_name: model_name,
        effort_tier: tier,
        effort_override: nil,
        supports_tools: false,
        supports_vision: false,
        supports_structured_output: false,
        min_confidence: nil,
        tags: [],
        flags: %{},
        priority: 10,
        enabled: true,
        context_window: 128_000,
        market_input_price_per_1m: nil,
        market_output_price_per_1m: nil,
        lanes: [lane(model_name, lane_overrides)]
      },
      Map.drop(overrides, [:lane])
    )
  end

  def lane(model_name, overrides \\ %{}) do
    Map.merge(
      %{
        credential_id: "cred-#{model_name}",
        provider_model: "upstream-#{model_name}",
        priority: 1,
        input_cost_per_million: Decimal.new("1"),
        output_cost_per_million: Decimal.new("1"),
        cache_cost_per_million: nil,
        pricing_unit: "per_1m_tokens",
        unit_cost: nil
      },
      overrides
    )
  end

  def model(model_name, overrides \\ %{}) do
    Map.merge(
      %{
        id: "model-#{model_name}",
        name: model_name,
        model_type: "llm",
        context_window: 128_000,
        market_input_price_per_1m: nil,
        market_output_price_per_1m: nil,
        lanes: [lane(model_name)]
      },
      overrides
    )
  end

  def snapshot(use_cases, overrides \\ %{}) do
    models =
      use_cases
      |> Enum.flat_map(& &1.candidates)
      |> Enum.map(& &1.model_name)
      |> Enum.uniq()
      |> Map.new(&{&1, model(&1)})

    Map.merge(
      %{config: config(), use_cases: use_cases, rules: [], models: models, decision_model: nil},
      overrides
    )
  end

  def payload(text, extra \\ %{}) do
    Map.merge(%{"messages" => [%{"role" => "user", "content" => text}]}, extra)
  end

  def session_payload(system, opener, extra \\ %{}) do
    Map.merge(
      %{
        "messages" => [
          %{"role" => "system", "content" => system},
          %{"role" => "user", "content" => opener}
        ]
      },
      extra
    )
  end

  def decision_model(overrides \\ %{}) do
    Map.merge(%{id: "model-decider", name: "decider", model_type: "decision"}, overrides)
  end

  def classifier_answer(key, overrides \\ %{}) do
    Map.merge(
      %{
        use_case_key: key,
        effort: nil,
        confidence: 0.9,
        usage: %{"input_tokens" => 12},
        latency_ms: 5,
        model_id: "model-decider",
        probabilities: [],
        source: "classifier"
      },
      overrides
    )
  end
end
