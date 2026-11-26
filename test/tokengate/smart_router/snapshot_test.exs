defmodule Tokengate.SmartRouter.SnapshotTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.{Config, Rule, UseCase, UseCaseModel}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Router Prov #{unique}",
        base_url: "https://router-#{unique}.example.com/v1"
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "Router Key #{unique}",
        api_key_encrypted: "sk-router-#{unique}",
        status: "active"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: "router-loader-#{unique}",
        context_window: 64_000,
        model_type: "llm"
      })

    {:ok, _lane} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "upstream/#{unique}",
        priority: 1,
        enabled: true,
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("4")
      })

    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(%{key: "loader_case_#{unique}", name: "Loader #{unique}"})
      |> Repo.insert()

    {:ok, binding} =
      %UseCaseModel{}
      |> UseCaseModel.changeset(%{
        router_use_case_id: use_case.id,
        target_model_id: model.id,
        effort_tier: "high",
        supports_tools: true,
        min_confidence: Decimal.new("0.600")
      })
      |> Repo.insert()

    {:ok, rule} =
      %Rule{}
      |> Rule.changeset(%{
        name: "loader rule #{unique}",
        action: "restrict_use_cases",
        target_use_case_keys: [use_case.key]
      })
      |> Repo.insert()

    config =
      Config.ensure!()
      |> Config.changeset(%{
        enabled: true,
        decision_model_id: model.id,
        default_model_id: model.id
      })
      |> Repo.update!()

    %{
      config: config,
      model: model,
      use_case: use_case,
      binding: binding,
      rule: rule
    }
  end

  test "loads config, use cases, destinations, rules and the decision model", %{
    config: config,
    model: model,
    use_case: use_case,
    binding: binding,
    rule: rule
  } do
    snapshot = SmartRouter.snapshot()

    assert snapshot.config.id == config.id
    assert snapshot.config.enabled
    assert snapshot.decision_model.id == model.id

    assert Enum.any?(snapshot.rules, &(&1.id == rule.id))

    loaded = Enum.find(snapshot.use_cases, &(&1.id == use_case.id))
    assert loaded
    assert loaded.key == use_case.key

    assert [candidate] = loaded.candidates
    assert candidate.model_id == model.id
    assert candidate.id == binding.id
    assert candidate.effort_tier == "high"
    assert candidate.supports_tools
    assert candidate.min_confidence == 0.6
    assert candidate.context_window == 64_000

    assert [lane] = candidate.lanes
    assert String.starts_with?(lane.provider_model, "upstream/")
    assert lane.priority == 1
    assert Decimal.equal?(lane.input_cost_per_million, Decimal.new("3"))

    assert {:ok, resolved} = SmartRouter.resolve_decision_lane(model.id)
    assert resolved.model_id == model.id
    assert resolved.credential.id != nil
    assert resolved.provider_model == lane.provider_model
  end

  test "the snapshot is cached and invalidate/0 makes a write visible", %{use_case: use_case} do
    first = SmartRouter.snapshot()

    assert {:ok, _} =
             use_case
             |> UseCase.changeset(%{name: "Renamed by operator"})
             |> Repo.update()

    assert SmartRouter.snapshot() == first

    SmartRouter.invalidate()

    renamed = Enum.find(SmartRouter.snapshot().use_cases, &(&1.id == use_case.id))
    assert renamed.name == "Renamed by operator"
  end
end
