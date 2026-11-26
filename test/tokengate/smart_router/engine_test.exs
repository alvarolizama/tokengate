defmodule Tokengate.SmartRouter.EngineTest do
  # Sync on purpose: this module exercise the GLOBAL caches (`DecisionCache`,
  # `SmartRouter.snapshot/0`) and invalidates them, which would race any async
  # module reading the same keys.
  use Tokengate.DataCase, async: false

  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.SessionPin
  alias Tokengate.SmartRouterFixtures, as: F

  defp cand(use_case_key, model, tier, price \\ "1", overrides \\ %{}) do
    F.candidate(
      use_case_key,
      model,
      tier,
      Map.merge(
        %{
          lane: %{
            input_cost_per_million: Decimal.new(price),
            output_cost_per_million: Decimal.new(price)
          }
        },
        overrides
      )
    )
  end

  defp run(snapshot, payload), do: run(snapshot, payload, %{}, [])

  defp run(snapshot, payload, context) when is_map(context),
    do: run(snapshot, payload, context, [])

  defp run(snapshot, payload, opts) when is_list(opts), do: run(snapshot, payload, %{}, opts)

  defp run(snapshot, payload, context, opts) do
    SmartRouter.decide(
      payload,
      context,
      Keyword.merge([snapshot: snapshot, health_fun: fn _lane -> true end], opts)
    )
  end

  defp two_use_cases(config \\ %{}) do
    fast =
      F.with_candidates(F.use_case("fast", %{priority: 10}), [cand("fast", "cheap", "low", "1")])

    writing =
      F.with_candidates(F.use_case("writing", %{priority: 20}), [
        cand("writing", "prose", "medium", "5")
      ])

    F.snapshot([fast, writing], %{config: F.config(config)})
  end

  defp writing_and_debug(config \\ %{}) do
    writing =
      F.with_candidates(F.use_case("writing", %{priority: 20}), [
        cand("writing", "prose", "medium", "1")
      ])

    debug =
      F.with_candidates(F.use_case("debug", %{priority: 30}), [
        cand("debug", "fast-debug", "low", "1", %{min_confidence: 0.9}),
        cand("debug", "slow-debug", "high", "10")
      ])

    F.snapshot([writing, debug], %{config: F.config(config)})
  end

  describe "Layer 1 — deterministic" do
    test "no decision model means no classifier, even with two viable use cases" do
      parent = self()

      assert {:ok, decision} =
               run(two_use_cases(), F.payload("hola"),
                 classifier_fun: fn _m, _a, _u ->
                   send(parent, :classifier_called)
                   {:error, :must_not_run}
                 end
               )

      refute_received :classifier_called
      assert decision.decision_meta.source == "deterministic"
      assert decision.decision_meta.classifier == false
      assert decision.use_case.key == "fast"
      assert decision.primary.model_name == "cheap"
    end

    test "a single viable use case short-circuits before the classifier" do
      only =
        F.with_candidates(F.use_case("writing"), [
          cand("writing", "prose", "low", "2"),
          cand("writing", "prose-high", "high", "9")
        ])

      snapshot =
        F.snapshot([only], %{
          config: F.config(%{decision_model_id: "model-decider"}),
          decision_model: F.decision_model()
        })

      assert {:ok, decision} =
               run(snapshot, F.payload("write"),
                 classifier_fun: fn _m, _a, _u -> {:error, :must_not_run} end
               )

      assert decision.decision_meta.source == "single_candidate"
      assert decision.primary.effort_tier == "low"
    end

    test "the fast path picks the fast use case for a trivial prompt" do
      assert {:ok, decision} =
               run(two_use_cases(%{fast_path_max_tokens: 400}), F.payload("hola"))

      assert decision.decision_meta.source == "fast_path"
      assert decision.use_case.key == "fast"
    end

    test "a force rule wins over the fast path and the classifier" do
      rules = [
        %{
          name: "forced writing",
          priority: 10,
          enabled: true,
          action: "force_use_case",
          target_use_case_keys: ["writing"],
          match_conditions: %{}
        }
      ]

      snapshot = two_use_cases(%{fast_path_max_tokens: 400})
      snapshot = %{snapshot | rules: rules, decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("hola"),
                 classifier_fun: fn _m, _a, _u -> {:error, :must_not_run} end
               )

      assert decision.decision_meta.source == "rule"
      assert decision.use_case.key == "writing"
      assert decision.decision_meta.rules == ["forced writing"]
    end

    test "a restriction narrows the candidate set before the classifier" do
      rules = [
        %{
          name: "only writing",
          priority: 10,
          enabled: true,
          action: "restrict_use_cases",
          target_use_case_keys: ["writing"],
          match_conditions: %{}
        }
      ]

      snapshot = two_use_cases()
      snapshot = %{snapshot | rules: rules}

      assert {:ok, decision} = run(snapshot, F.payload("hola"))
      assert decision.use_case.key == "writing"
      assert decision.decision_meta.source == "single_candidate"
    end

    test "capability and context-window pre-filters drop unusable destinations" do
      tiny =
        F.with_candidates(F.use_case("tiny"), [
          cand("tiny", "tiny-model", "low", "1", %{context_window: 10})
        ])

      writing =
        F.with_candidates(F.use_case("writing"), [cand("writing", "prose", "low", "5")])

      snapshot = F.snapshot([tiny, writing])

      assert {:ok, decision} = run(snapshot, F.payload(String.duplicate("x", 40_000)))
      assert decision.use_case.key == "writing"

      only_tiny = F.snapshot([tiny])
      assert {:error, :no_candidates} = run(only_tiny, F.payload(String.duplicate("x", 40_000)))
    end

    test "a tools-requiring use case needs a destination that supports tools" do
      coding =
        F.with_candidates(F.use_case("coding_implement", %{requires_tools: true}), [
          cand("coding_implement", "no-tools", "low", "1", %{supports_tools: false}),
          cand("coding_implement", "tools", "high", "5", %{supports_tools: true})
        ])

      snapshot = F.snapshot([coding])

      payload =
        F.payload("fix it", %{
          "tools" => [%{"type" => "function", "function" => %{"name" => "edit"}}]
        })

      assert {:ok, decision} = run(snapshot, payload)
      assert decision.primary.model_name == "tools"
    end
  end

  describe "Layer 2 — classifier" do
    test "is invoked only with two viable use cases, a decision model and no shortcut" do
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("write a long email"),
                 classifier_fun: fn _model, _analysis, _use_cases ->
                   {:ok, F.classifier_answer("writing", %{effort: "medium"})}
                 end
               )

      assert decision.decision_meta.source == "classifier"
      assert decision.decision_meta.classifier
      assert decision.decision_meta.confidence == 0.9
      assert decision.decision_meta.usage == %{"input_tokens" => 12}
      assert decision.decision_meta.classifier_ms == 5
      assert decision.use_case.key == "writing"
    end

    test "a repeated question is answered from the decision cache" do
      parent = self()
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      fun = fn _model, _analysis, _use_cases ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      assert {:ok, first} = run(snapshot, F.payload("same template"), classifier_fun: fun)
      assert {:ok, second} = run(snapshot, F.payload("same template"), classifier_fun: fun)

      assert first.decision_meta.source == "classifier"
      assert second.decision_meta.source == "decision_cache"
      assert second.decision_meta.cache_hit
      assert second.decision_meta.classifier == false
      assert_received :classified
      refute_received :classified
    end

    test "a classifier timeout falls back deterministically and says so" do
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("hello"),
                 classifier_fun: fn _m, _a, _u -> {:error, :timeout} end
               )

      assert decision.decision_meta.source == "fallback_timeout"
      assert decision.decision_meta.fallback_reason == :timeout
      assert decision.decision_meta.timeout
      assert decision.use_case.key == "fast"
    end

    test "a classifier error falls back deterministically and says so" do
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("hello"),
                 classifier_fun: fn _m, _a, _u -> {:error, :server_error} end
               )

      assert decision.decision_meta.source == "fallback_error"
      assert decision.decision_meta.fallback_reason == :server_error
      refute decision.decision_meta.timeout
    end

    test "an unknown use case from the classifier is treated as a failure" do
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("hello"),
                 classifier_fun: fn _m, _a, _u -> {:ok, F.classifier_answer("ghost")} end
               )

      assert decision.decision_meta.source == "fallback_error"
      assert decision.decision_meta.fallback_reason == :unknown_use_case
    end

    test "a decision cache hit does not bill or report the classifier call" do
      parent = self()
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      fun = fn _m, _a, _u ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      assert {:ok, first} = run(snapshot, F.payload("same template"), classifier_fun: fun)
      assert first.decision_meta.source == "classifier"
      assert first.decision_meta.usage == %{"input_tokens" => 12}
      assert first.decision_meta.classifier_ms == 5

      assert {:ok, second} = run(snapshot, F.payload("same template"), classifier_fun: fun)

      assert second.decision_meta.source == "decision_cache"
      assert second.decision_meta.cache_hit
      refute second.decision_meta.classifier
      assert second.decision_meta.usage == nil
      assert second.decision_meta.classifier_ms == nil
      assert_received :classified
      refute_received :classified
    end
  end

  describe "Layer 3 — ranking and escalation" do
    test "low confidence escalates upward instead of downgrading" do
      snapshot = %{writing_and_debug() | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("why does this crash?"),
                 classifier_fun: fn _m, _a, _u ->
                   {:ok, F.classifier_answer("debug", %{effort: "low", confidence: 0.4})}
                 end
               )

      assert decision.use_case.key == "debug"
      assert decision.primary.effort_tier == "high"
      assert decision.decision_meta.escalated
    end

    test "critical_accuracy ranks the potent tier above the cheap one" do
      debug =
        F.with_candidates(F.use_case("debug", %{critical_accuracy: true}), [
          cand("debug", "cheap-debug", "low", "1"),
          cand("debug", "strong-debug", "high", "10")
        ])

      snapshot =
        F.snapshot([debug], %{
          config: F.config(%{decision_model_id: "model-decider"}),
          decision_model: F.decision_model()
        })

      assert {:ok, decision} =
               run(snapshot, F.payload("root cause please"),
                 classifier_fun: fn _m, _a, _u -> {:ok, F.classifier_answer("debug")} end
               )

      assert decision.primary.model_name == "strong-debug"
    end

    test "the fallback chain is same tier -> potent -> fallback model -> global default" do
      debug =
        F.with_candidates(
          F.use_case("debug", %{allow_downgrade: false, fallback_model_id: "model-fallback"}),
          [
            cand("debug", "low-a", "low", "1"),
            cand("debug", "low-b", "low", "2"),
            cand("debug", "medium", "medium", "3"),
            cand("debug", "high", "high", "4")
          ]
        )

      writing =
        F.with_candidates(F.use_case("writing", %{priority: 20}), [
          cand("writing", "prose", "low", "1")
        ])

      base = F.snapshot([writing, debug])
      models = Map.merge(base.models, %{"model-fallback" => F.model("fallback")})

      snapshot = %{
        base
        | config:
            F.config(%{default_model_id: "model-default", decision_model_id: "model-decider"}),
          decision_model: F.decision_model(),
          models: Map.put(models, "model-default", F.model("default"))
      }

      assert {:ok, decision} =
               run(snapshot, F.payload("trace it"),
                 classifier_fun: fn _m, _a, _u ->
                   {:ok, F.classifier_answer("debug", %{effort: "low", confidence: 1.0})}
                 end
               )

      assert decision.primary.model_name == "low-a"

      assert Enum.map(decision.fallbacks, & &1.model_name) ==
               ~w(low-b medium high fallback default)
    end

    test "allow_downgrade adds the cheaper tier after the potent ones" do
      debug =
        F.with_candidates(F.use_case("debug", %{allow_downgrade: true}), [
          cand("debug", "low", "low", "1"),
          cand("debug", "medium", "medium", "3"),
          cand("debug", "high", "high", "4")
        ])

      writing =
        F.with_candidates(F.use_case("writing", %{priority: 20}), [
          cand("writing", "prose", "low", "1")
        ])

      snapshot = %{F.snapshot([writing, debug]) | decision_model: F.decision_model()}

      assert {:ok, decision} =
               run(snapshot, F.payload("think about it"),
                 classifier_fun: fn _m, _a, _u ->
                   {:ok, F.classifier_answer("debug", %{effort: "medium", confidence: 1.0})}
                 end
               )

      assert decision.primary.effort_tier == "medium"

      assert Enum.map(decision.fallbacks, & &1.model_name) == ~w(high low)
    end

    test "the prompt policy travels with the decision" do
      writing =
        F.with_candidates(
          F.use_case("writing", %{
            max_history_turns: 20,
            compact_json: true,
            keep_last_n_images: 2,
            stale_tool_trim_threshold_pct: 40
          }),
          [cand("writing", "prose", "low")]
        )

      assert {:ok, decision} = run(F.snapshot([writing]), F.payload("write"))

      assert decision.prompt_policy == %{
               keep_last_n_images: 2,
               max_history_turns: 20,
               compact_json: true,
               stale_tool_trim_threshold_pct: 40
             }
    end
  end

  describe "Layer 0 — session pin" do
    test "a live conversation keeps its model and skips the classifier" do
      parent = self()
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      fun = fn _m, _a, _u ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      payload = F.session_payload("You are a writer", "write it")

      assert {:ok, first} =
               run(snapshot, payload, %{subject_id: "subject-1"}, classifier_fun: fun)

      assert {:ok, second} =
               run(snapshot, payload, %{subject_id: "subject-1"}, classifier_fun: fun)

      assert first.decision_meta.source == "classifier"
      assert second.decision_meta.source == "session_pin"
      assert second.decision_meta.pinned
      assert second.primary.model_name == first.primary.model_name
      assert_received :classified
      refute_received :classified

      assert %{model_id: pinned_model} = SessionPin.get("subject-1", session_key(payload))
      assert pinned_model == first.primary.model_id
    end

    test "a capability upgrade the pinned model cannot serve breaks the pin" do
      writing =
        F.with_candidates(F.use_case("writing"), [cand("writing", "prose", "low", "1")])

      coding =
        F.with_candidates(F.use_case("coding_implement", %{requires_tools: true}), [
          cand("coding_implement", "tools", "high", "5", %{supports_tools: true})
        ])

      snapshot = %{F.snapshot([writing, coding]) | decision_model: nil}
      payload = F.session_payload("You are helpful", "hello")

      assert {:ok, first} = run(snapshot, payload, %{subject_id: "subject-2"})
      assert first.decision_meta.source == "deterministic"

      payload_with_tools =
        Map.put(payload, "tools", [
          %{"type" => "function", "function" => %{"name" => "edit"}}
        ])

      assert {:ok, second} = run(snapshot, payload_with_tools, %{subject_id: "subject-2"})

      refute second.decision_meta.source == "session_pin"
      refute second.decision_meta.pinned
      # `prose` cannot serve tools, so it is not even a candidate any more: the
      # request re-decides onto the tool-capable destination and re-pins.
      assert second.primary.model_name == "tools"

      # The old pin is gone; the request re-decides and pins the new shape.
      assert %{requirements: %{tools: true}, model_id: "model-tools"} =
               SessionPin.get("subject-2", session_key(payload))
    end

    test "a capability the pinned model already supports keeps the pin" do
      writing =
        F.with_candidates(F.use_case("writing"), [
          cand("writing", "prose", "low", "1", %{supports_tools: true, supports_vision: true})
        ])

      snapshot = F.snapshot([writing])
      payload = F.session_payload("You are helpful", "hello")

      assert {:ok, first} = run(snapshot, payload, %{subject_id: "subject-2b"})
      assert first.decision_meta.source == "single_candidate"

      payload_with_tools =
        Map.put(payload, "tools", [
          %{"type" => "function", "function" => %{"name" => "edit"}}
        ])

      assert {:ok, second} = run(snapshot, payload_with_tools, %{subject_id: "subject-2b"})

      assert second.decision_meta.source == "session_pin"
      assert second.primary.model_name == "prose"
    end

    test "an open tool loop keeps the pin (lock_tool_loops defaults to true)" do
      parent = self()

      fast =
        F.with_candidates(F.use_case("fast", %{priority: 10}), [
          cand("fast", "cheap", "low", "1", %{supports_tools: true})
        ])

      writing =
        F.with_candidates(F.use_case("writing", %{priority: 20}), [
          cand("writing", "prose", "medium", "5", %{supports_tools: true})
        ])

      snapshot = %{F.snapshot([fast, writing]) | decision_model: F.decision_model()}

      fun = fn _m, _a, _u ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      payload =
        F.session_payload("You are an agent", "run the tests")
        |> Map.put("tools", [%{"type" => "function", "function" => %{"name" => "run"}}])

      assert {:ok, _first} =
               run(snapshot, payload, %{subject_id: "subject-loop"}, classifier_fun: fun)

      loop_payload =
        Map.put(payload, "messages", [
          %{"role" => "system", "content" => "You are an agent"},
          %{"role" => "user", "content" => "run the tests"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c1", "type" => "function", "function" => %{"name" => "run"}}
            ]
          },
          %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"}
        ])

      assert {:ok, second} =
               run(snapshot, loop_payload, %{subject_id: "subject-loop"}, classifier_fun: fun)

      assert second.decision_meta.source == "session_pin"
      assert_received :classified
      refute_received :classified
    end

    test "lock_tool_loops: false lets the operator re-decide mid-loop" do
      parent = self()

      fast =
        F.with_candidates(F.use_case("fast", %{priority: 10}), [
          cand("fast", "cheap", "low", "1", %{supports_tools: true})
        ])

      writing =
        F.with_candidates(F.use_case("writing", %{priority: 20}), [
          cand("writing", "prose", "medium", "5", %{supports_tools: true})
        ])

      snapshot =
        %{
          F.snapshot([fast, writing], %{config: F.config(%{lock_tool_loops: false})})
          | decision_model: F.decision_model()
        }

      fun = fn _m, _a, _u ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      payload =
        F.session_payload("You are an agent", "run the tests")
        |> Map.put("tools", [%{"type" => "function", "function" => %{"name" => "run"}}])

      assert {:ok, _first} =
               run(snapshot, payload, %{subject_id: "subject-loop-2"}, classifier_fun: fun)

      loop_payload =
        Map.put(payload, "messages", [
          %{"role" => "system", "content" => "You are an agent"},
          %{"role" => "user", "content" => "run the tests"},
          %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"}
        ])

      assert {:ok, second} =
               run(snapshot, loop_payload, %{subject_id: "subject-loop-2"}, classifier_fun: fun)

      refute second.decision_meta.source == "session_pin"
      refute second.decision_meta.pinned
      assert_received :classified
      refute_received :classified
    end

    test "pin_session false never pins" do
      writing =
        F.with_candidates(F.use_case("writing", %{pin_session: false}), [
          cand("writing", "prose", "low", "1")
        ])

      snapshot = F.snapshot([writing])
      payload = F.session_payload("You are helpful", "hello")

      assert {:ok, _first} = run(snapshot, payload, %{subject_id: "subject-3"})
      assert {:ok, second} = run(snapshot, payload, %{subject_id: "subject-3"})

      refute second.decision_meta.source == "session_pin"
      assert SessionPin.get("subject-3", session_key(payload)) == nil
    end

    test "a nil session key is never pinned" do
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}
      payload = F.payload("one-shot")

      fun = fn _m, _a, _u -> {:ok, F.classifier_answer("fast")} end

      assert {:ok, first} =
               run(snapshot, payload, %{subject_id: "subject-4"}, classifier_fun: fun)

      assert {:ok, second} =
               run(snapshot, payload, %{subject_id: "subject-4"}, classifier_fun: fun)

      refute first.decision_meta.source == "session_pin"
      refute second.decision_meta.source == "session_pin"
    end
  end

  describe "dry_run and config" do
    test "dry_run writes neither the pin nor the classifier cache" do
      parent = self()
      snapshot = %{two_use_cases() | decision_model: F.decision_model()}

      fun = fn _m, _a, _u ->
        send(parent, :classified)
        {:ok, F.classifier_answer("writing", %{effort: "medium"})}
      end

      payload = F.session_payload("You are helpful", "write")
      opts = [snapshot: snapshot, health_fun: fn _ -> true end, classifier_fun: fun]

      assert {:ok, first} = SmartRouter.dry_run(payload, %{subject_id: "subject-dry"}, opts)
      assert {:ok, second} = SmartRouter.dry_run(payload, %{subject_id: "subject-dry"}, opts)

      assert first.decision_meta.dry_run
      assert second.decision_meta.dry_run
      assert second.decision_meta.source == "classifier"
      assert_received :classified
      assert_received :classified
      assert SessionPin.get("subject-dry", session_key(payload)) == nil

      assert {:ok, third} = SmartRouter.decide(payload, %{subject_id: "subject-dry"}, opts)
      refute third.decision_meta.dry_run

      assert %{model_id: pinned_model} = SessionPin.get("subject-dry", session_key(payload))
      assert pinned_model == third.primary.model_id
    end

    test "a disabled router returns the kill-switch error" do
      snapshot = %{two_use_cases() | config: F.config(%{enabled: false})}
      assert {:error, :router_disabled} = run(snapshot, F.payload("hola"))
    end

    test "the decision carries a cost estimate for the primary and fallbacks" do
      assert {:ok, decision} = run(two_use_cases(), F.payload("hola"))

      assert %Decimal{} = decision.primary.cost_usd

      assert Enum.all?(decision.fallbacks, fn fallback ->
               is_nil(fallback.cost_usd) or match?(%Decimal{}, fallback.cost_usd)
             end)
    end
  end

  describe "Track A fixes — request capabilities, health, unpriced, effort override" do
    test "the request's own capabilities filter destinations even when the use case does not require them" do
      writing =
        F.with_candidates(F.use_case("writing"), [
          cand("writing", "text-only", "low", "1"),
          cand("writing", "multimodal", "high", "5", %{
            supports_tools: true,
            supports_vision: true,
            supports_structured_output: true
          })
        ])

      snapshot = F.snapshot([writing])

      tools =
        F.payload("fix it", %{
          "tools" => [%{"type" => "function", "function" => %{"name" => "edit"}}]
        })

      vision = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "what is this?"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
            ]
          }
        ]
      }

      structured =
        F.payload("extract", %{
          "response_format" => %{"type" => "json_schema", "json_schema" => %{}}
        })

      for payload <- [tools, vision, structured] do
        assert {:ok, decision} = run(snapshot, payload)
        assert decision.primary.model_name == "multimodal"
      end

      assert {:ok, text} = run(snapshot, F.payload("just text"))
      assert text.primary.model_name == "text-only"
    end

    test "the fast path does not fire for vision or structured output" do
      fast =
        F.with_candidates(F.use_case("fast", %{priority: 10}), [
          cand("fast", "cheap", "low", "1", %{
            supports_vision: true,
            supports_structured_output: true
          })
        ])

      writing =
        F.with_candidates(F.use_case("writing", %{priority: 20}), [
          cand("writing", "prose", "medium", "5", %{
            supports_vision: true,
            supports_structured_output: true
          })
        ])

      snapshot =
        F.snapshot([fast, writing], %{config: F.config(%{fast_path_max_tokens: 400})})

      assert {:ok, plain} = run(snapshot, F.payload("hola"))
      assert plain.decision_meta.source == "fast_path"

      vision = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "hola"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
            ]
          }
        ]
      }

      assert {:ok, with_image} = run(snapshot, vision)
      refute with_image.decision_meta.source == "fast_path"

      structured =
        F.payload("hola", %{"response_format" => %{"type" => "json_schema", "json_schema" => %{}}})

      assert {:ok, with_schema} = run(snapshot, structured)
      refute with_schema.decision_meta.source == "fast_path"
    end

    test "a healthy destination outranks a cheaper degraded one" do
      debug =
        F.with_candidates(F.use_case("debug"), [
          cand("debug", "cheap", "low", "1"),
          cand("debug", "pricey", "low", "5")
        ])

      snapshot = F.snapshot([debug])
      health = fn lane -> lane.credential_id != "cred-cheap" end

      assert {:ok, decision} = run(snapshot, F.payload("debug this"), %{}, health_fun: health)
      assert decision.primary.model_name == "pricey"

      # With no healthy destination at all the degraded ladder still answers.
      assert {:ok, degraded} =
               run(snapshot, F.payload("debug this"), %{}, health_fun: fn _lane -> false end)

      assert degraded.primary.model_name == "cheap"
    end

    test "an unpriced use case never wins on price alone" do
      unpriced =
        F.with_candidates(F.use_case("unpriced", %{priority: 10}), [
          cand("unpriced", "free-looking", "low", "1", %{
            lane: %{input_cost_per_million: nil, output_cost_per_million: nil}
          })
        ])

      priced =
        F.with_candidates(F.use_case("priced", %{priority: 20}), [
          cand("priced", "fifteen", "low", "1.5")
        ])

      snapshot = F.snapshot([unpriced, priced])

      assert {:ok, decision} = run(snapshot, F.payload("hola"))
      assert decision.use_case.key == "priced"
      assert %Decimal{} = decision.primary.cost_usd
    end

    test "the destination carries its binding's effort_override" do
      writing =
        F.with_candidates(F.use_case("writing"), [
          cand("writing", "prose", "low", "1", %{effort_override: "high"})
        ])

      snapshot = F.snapshot([writing])

      assert {:ok, decision} = run(snapshot, F.payload("write"))
      assert decision.primary.effort_override == "high"

      assert SmartRouter.effort_override(decision.primary.use_case_model_id, snapshot: snapshot) ==
               "high"

      assert SmartRouter.effort_override("bind-unknown", snapshot: snapshot) == nil
      assert SmartRouter.effort_override(nil) == nil
    end

    test "invalidate drops the decision cache" do
      alias Tokengate.SmartRouter.DecisionCache

      key = DecisionCache.fingerprint({:invalidate, System.unique_integer([:positive])})
      DecisionCache.put(key, %{use_case_key: "fast"})
      assert DecisionCache.get(key) != nil

      assert :ok = SmartRouter.invalidate()
      assert DecisionCache.get(key) == nil
    end

    test "a model update drops the router's per-model cache" do
      unique = System.unique_integer([:positive])

      {:ok, model} =
        Tokengate.Providers.create_model(%{name: "router-inv-#{unique}", context_window: 8_000})

      key = {:router_model_by_id, model.id}
      ttl = :timer.minutes(1)

      assert %{stale: true} = Tokengate.Cache.fetch(key, ttl, fn -> %{stale: true} end)

      {:ok, _updated} = Tokengate.Providers.update_model(model, %{context_window: 16_000})

      assert Tokengate.Cache.fetch(key, ttl, fn -> :refetched end) == :refetched
    end

    test "resolve_decision_lane expands a credential pool into a usable lane" do
      unique = System.unique_integer([:positive])

      {:ok, provider} =
        Tokengate.Providers.create_provider(%{
          name: "Decider Prov #{unique}",
          base_url: "https://decider-#{unique}.example.com/v1"
        })

      {:ok, key_a} =
        Tokengate.Providers.create_credential(%{
          provider_id: provider.id,
          name: "decider-a #{unique}",
          api_key_encrypted: "sk-a-#{unique}",
          status: "active"
        })

      {:ok, key_b} =
        Tokengate.Providers.create_credential(%{
          provider_id: provider.id,
          name: "decider-b #{unique}",
          api_key_encrypted: "sk-b-#{unique}",
          status: "active"
        })

      {:ok, pool} =
        Tokengate.Providers.create_pool(provider, %{name: "decider-pool-#{unique}"})

      {:ok, _} = Tokengate.Providers.add_pool_member(pool, key_a)
      {:ok, _} = Tokengate.Providers.add_pool_member(pool, key_b)

      {:ok, model} =
        Tokengate.Providers.create_model(%{
          name: "decider-model-#{unique}",
          context_window: 8_000,
          model_type: "decision"
        })

      # A lane mounted on a pool: `credential_id` is NULL, the members are the keys.
      {:ok, _lane} =
        Tokengate.Providers.create_model_provider(%{
          model_id: model.id,
          pool_id: pool.id,
          provider_model: "upstream/#{unique}",
          priority: 1,
          enabled: true
        })

      assert {:ok, lane} = SmartRouter.resolve_decision_lane(model.id)
      assert lane.provider_model == "upstream/#{unique}"
      assert lane.model_provider.pool_id == pool.id
      assert lane.credential.id in [key_a.id, key_b.id]
      assert lane.model_type == "decision"
    end
  end

  # Mirrors `Proxy.SessionId`'s derivation for the two-message fixture.
  defp session_key(payload) do
    Tokengate.Proxy.SessionId.derive(payload, nil)
  end
end
