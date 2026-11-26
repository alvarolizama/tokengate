defmodule Tokengate.SmartRouter.SchemaTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Config
  alias Tokengate.SmartRouter.Rule
  alias Tokengate.SmartRouter.UseCase
  alias Tokengate.SmartRouter.UseCaseModel

  defp model_fixture(attrs \\ %{}) do
    {:ok, model} =
      Providers.create_model(
        Map.merge(
          %{
            "name" => "router-test-model-#{System.unique_integer([:positive])}",
            "context_window" => 128_000,
            "model_type" => "llm"
          },
          attrs
        )
      )

    model
  end

  defp use_case_fixture(attrs \\ %{}) do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(
        Map.merge(
          %{key: "case_#{System.unique_integer([:positive])}", name: "Caso"},
          attrs
        )
      )
      |> Repo.insert()

    use_case
  end

  describe "router_configs (singleton)" do
    test "ensure!/0 creates one disabled row and is idempotent" do
      assert %Config{enabled: false} = config = Config.ensure!()
      assert config.id == Config.singleton_id()
      assert Config.get().id == config.id

      assert Config.ensure!().id == config.id
      assert Repo.aggregate(Config, :count) == 1
    end

    test "ensure!/0 never overwrites operator settings" do
      config = Config.ensure!()

      {:ok, edited} =
        config
        |> Config.changeset(%{enabled: true, policy: "cost_first", decision_timeout_ms: 250})
        |> Repo.update()

      assert Config.ensure!().id == edited.id
      reloaded = Config.get()
      assert reloaded.enabled
      assert reloaded.policy == "cost_first"
      assert reloaded.decision_timeout_ms == 250
    end

    test "the database allows only one is_default = true row" do
      config = Config.ensure!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Postgrex.Error, ~r/router_configs_single_default_idx/, fn ->
        Repo.insert_all(Config, [
          %{
            id: Ecto.UUID.generate(),
            name: "Segunda default",
            is_default: true,
            inserted_at: now,
            updated_at: now
          }
        ])
      end

      # A candidate version (not the Default) is not capped: versions are the
      # whole point, only the serving Default is unique.
      assert {1, _} =
               Repo.insert_all(Config, [
                 %{
                   id: Ecto.UUID.generate(),
                   name: "Candidata",
                   inserted_at: now,
                   updated_at: now
                 }
               ])

      assert Config.get().id == config.id
    end

    test "changeset/2 validates the policy and the bounded knobs" do
      refute Config.changeset(%Config{}, %{policy: "vibes"}).valid?
      refute Config.changeset(%Config{}, %{decision_timeout_ms: 0}).valid?
      refute Config.changeset(%Config{}, %{decision_context_chars: 0}).valid?
      refute Config.changeset(%Config{}, %{fast_path_max_tokens: -1}).valid?

      assert Config.changeset(%Config{}, %{
               policy: "quality_first",
               decision_timeout_ms: 1,
               fast_path_max_tokens: 0
             }).valid?
    end

    test "changeset/2 rejects a model pointer that does not exist" do
      changeset = Config.changeset(Config.ensure!(), %{decision_model_id: Ecto.UUID.generate()})
      assert {:error, changeset} = Repo.update(changeset)
      assert %{decision_model_id: ["does not exist"]} = errors_on(changeset)
    end

    test "an existing model can be pointed at and survives the config row" do
      model = model_fixture()
      config = Config.ensure!()

      {:ok, config} =
        config
        |> Config.changeset(%{
          decision_model_id: model.id,
          default_model_id: model.id,
          baseline_model_id: model.id
        })
        |> Repo.update()

      assert config.decision_model_id == model.id
      assert config.baseline_model_id == model.id
    end
  end

  describe "router_use_case_models" do
    test "binds a model to a use case with an effort tier" do
      use_case = use_case_fixture()
      model = model_fixture()

      assert {:ok, binding} =
               %UseCaseModel{}
               |> UseCaseModel.changeset(%{
                 router_use_case_id: use_case.id,
                 target_model_id: model.id,
                 effort_tier: "high",
                 effort_override: "high",
                 supports_tools: true,
                 min_confidence: Decimal.new("0.700")
               })
               |> Repo.insert()

      assert binding.effort_tier == "high"
      assert Decimal.equal?(binding.min_confidence, Decimal.new("0.700"))
    end

    test "the same model can sit in one use case under different tiers, once each" do
      use_case = use_case_fixture()
      model = model_fixture()

      for tier <- ~w(low high) do
        assert {:ok, _} =
                 %UseCaseModel{}
                 |> UseCaseModel.changeset(%{
                   router_use_case_id: use_case.id,
                   target_model_id: model.id,
                   effort_tier: tier
                 })
                 |> Repo.insert()
      end

      assert {:error, changeset} =
               %UseCaseModel{}
               |> UseCaseModel.changeset(%{
                 router_use_case_id: use_case.id,
                 target_model_id: model.id,
                 effort_tier: "low"
               })
               |> Repo.insert()

      assert %{
               router_use_case_id: [
                 "has already been taken"
               ]
             } = errors_on(changeset)
    end

    test "rejects an unknown effort tier and a confidence out of range" do
      use_case = use_case_fixture()
      model = model_fixture()

      refute UseCaseModel.changeset(%UseCaseModel{}, %{
               router_use_case_id: use_case.id,
               target_model_id: model.id,
               effort_tier: "extreme"
             }).valid?

      refute UseCaseModel.changeset(%UseCaseModel{}, %{
               router_use_case_id: use_case.id,
               target_model_id: model.id,
               min_confidence: Decimal.new("1.5")
             }).valid?
    end

    test "an empty effort override means unset, not an invalid value" do
      use_case = use_case_fixture()
      model = model_fixture()

      changeset =
        UseCaseModel.changeset(%UseCaseModel{}, %{
          router_use_case_id: use_case.id,
          target_model_id: model.id,
          effort_override: ""
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :effort_override) == nil
    end

    test "target_model_id is RESTRICTed and the constraint has the name the code expects" do
      %{rows: rows} =
        Repo.query!("""
        SELECT conname, pg_get_constraintdef(oid)
          FROM pg_constraint
         WHERE conrelid = 'router_use_case_models'::regclass
           AND contype = 'f'
           AND conname LIKE '%target_model_id%'
        """)

      assert [["router_use_case_models_target_model_id_fkey", definition]] = rows
      assert definition =~ "REFERENCES models(id)"
      assert definition =~ "ON DELETE RESTRICT"
    end

    test "deleting a use case deletes its bindings" do
      use_case = use_case_fixture()
      model = model_fixture()

      {:ok, _binding} =
        %UseCaseModel{}
        |> UseCaseModel.changeset(%{router_use_case_id: use_case.id, target_model_id: model.id})
        |> Repo.insert()

      assert {:ok, _} = Repo.delete(use_case)
      assert Repo.aggregate(UseCaseModel, :count) == 0
      assert Repo.get(Tokengate.Providers.Model, model.id)
    end
  end

  describe "router_rules" do
    test "accepts a force_use_case rule with known conditions" do
      assert Rule.changeset(%Rule{}, %{
               name: "conciliación a finanzas",
               action: "force_use_case",
               target_use_case_keys: ["data_heavy_finance"],
               priority: 10,
               match_conditions: %{
                 "content_regex" => "conciliaci[oó]n",
                 "min_tokens" => 1_000,
                 "has_tools" => true,
                 "reasoning_effort" => "high",
                 "agent_types" => ["codex"],
                 "group_ids" => [Ecto.UUID.generate()]
               }
             }).valid?
    end

    test "accepts a restrict_use_cases rule with several keys" do
      assert Rule.changeset(%Rule{}, %{
               name: "no degradar agentes",
               action: "restrict_use_cases",
               target_use_case_keys: ~w(coding_implement research),
               match_conditions: %{"has_tools" => true, "has_vision" => false}
             }).valid?
    end

    test "rejects an action outside the vocabulary" do
      changeset =
        Rule.changeset(%Rule{}, %{
          name: "x",
          action: "delete_everything",
          target_use_case_keys: ["fast"]
        })

      refute changeset.valid?
      assert errors_on(changeset).action == ["is invalid"]
    end

    test "rejects an unknown condition instead of ignoring it" do
      changeset =
        Rule.changeset(%Rule{}, %{
          name: "typo",
          action: "force_use_case",
          target_use_case_keys: ["fast"],
          match_conditions: %{"has_tool" => true}
        })

      refute changeset.valid?
      assert [message] = errors_on(changeset).match_conditions
      assert message =~ "unknown condition"
      assert message =~ "has_tool"
    end

    test "rejects a condition with the wrong type" do
      for conditions <- [
            %{"min_tokens" => "muchos"},
            %{"min_tokens" => -1},
            %{"has_tools" => "yes"},
            %{"reasoning_effort" => "maximum"},
            %{"agent_types" => "codex"},
            %{"content_regex" => "([unclosed"}
          ] do
        refute Rule.changeset(%Rule{}, %{
                 name: "bad",
                 action: "force_use_case",
                 target_use_case_keys: ["fast"],
                 match_conditions: conditions
               }).valid?,
               "expected #{inspect(conditions)} to be rejected"
      end
    end

    test "force_use_case needs exactly one target, restrict_use_cases at least one" do
      refute Rule.changeset(%Rule{}, %{
               name: "none",
               action: "force_use_case",
               target_use_case_keys: []
             }).valid?

      refute Rule.changeset(%Rule{}, %{
               name: "two",
               action: "force_use_case",
               target_use_case_keys: ~w(fast writing)
             }).valid?

      refute Rule.changeset(%Rule{}, %{
               name: "empty",
               action: "restrict_use_cases",
               target_use_case_keys: []
             }).valid?
    end

    test "the name is unique" do
      {:ok, _} =
        Repo.insert(
          Rule.changeset(%Rule{}, %{
            name: "regla",
            action: "force_use_case",
            target_use_case_keys: ["fast"]
          })
        )

      assert {:error, changeset} =
               Repo.insert(
                 Rule.changeset(%Rule{}, %{
                   name: "regla",
                   action: "force_use_case",
                   target_use_case_keys: ["writing"]
                 })
               )

      assert errors_on(changeset).name == ["has already been taken"]
    end
  end

  describe "migration artifacts" do
    test "the access flags live on the three subjects" do
      assert column?("groups", "router_enabled", "boolean", "NO")
      assert column?("groups", "router_baseline_model_id", "uuid", "YES")
      # Tri-state: nullable on purpose (nil = inherit from the profile).
      assert column?("group_members", "router_enabled", "boolean", "YES")
      assert column?("services", "router_enabled", "boolean", "NO")
    end

    test "request_logs carries the router metadata and no new FK" do
      for column <- ~w(session_id routed_via_router model_resolved router_use_case_id
                       router_use_case_key router_use_case_model_id router_effort_tier
                       router_decision_source router_decision_ms router_decision_cost_usd
                       router_baseline_model_id router_baseline_cost_usd router_direct_access
                       prompt_tokens_saved_est) do
        assert column?("request_logs", column), "missing request_logs.#{column}"
      end

      # Every router id is a plain uuid: request_logs must not gain FKs.
      %{rows: rows} =
        Repo.query!("""
        SELECT conname FROM pg_constraint
         WHERE conrelid = 'request_logs'::regclass AND contype = 'f'
        """)

      assert Enum.all?(rows, fn [name] ->
               name in ~w(request_logs_group_member_id_fkey request_logs_service_id_fkey)
             end)
    end

    test "the router index is partial on the parent and reaches every partition" do
      %{rows: [[definition]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
         WHERE indexname = 'request_logs_routed_via_router_inserted_at_idx'
        """)

      assert definition =~ "(inserted_at)"
      assert definition =~ "WHERE (routed_via_router = true)"

      %{rows: [[partitions]]} =
        Repo.query!("""
        SELECT count(*)
          FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
         WHERE p.relname = 'request_logs'
        """)

      %{rows: [[inherited]]} =
        Repo.query!("""
        SELECT count(*)
          FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
         WHERE p.relname = 'request_logs_routed_via_router_inserted_at_idx'
        """)

      assert partitions > 0
      assert inherited == partitions
    end
  end

  defp column?(table, column, type \\ nil, nullable \\ nil) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable FROM information_schema.columns
         WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [] ->
        false

      [[data_type, is_nullable]] ->
        (is_nil(type) or data_type == type) and (is_nil(nullable) or is_nullable == nullable)
    end
  end
end
