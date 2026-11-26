defmodule Tokengate.SmartRouter.RequestLogTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.{UseCase, UseCaseModel}

  defp member_fixture do
    {:ok, group} = Accounts.create_group(%{"name" => "G #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "router-log-#{System.unique_integer([:positive])}@example.com",
        "name" => "Router Log",
        "password" => "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    member
  end

  defp model_fixture do
    {:ok, model} =
      Providers.create_model(%{
        "name" => "log-model-#{System.unique_integer([:positive])}",
        "context_window" => 128_000
      })

    model
  end

  describe "permitted fields" do
    test "session_id is persisted (it used to be dropped silently)" do
      member = member_fixture()

      assert {:ok, log} =
               Logs.log_request(%{
                 subject_type: "user",
                 group_member_id: member.id,
                 model_requested: "glm-5.2",
                 session_id: "sess-#{System.unique_integer([:positive])}",
                 status_code: 200
               })

      reloaded = Repo.get_by!(RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded.session_id == log.session_id
      assert reloaded.session_id != nil
    end

    test "all thirteen router telemetry columns are persisted" do
      member = member_fixture()
      model = model_fixture()

      {:ok, use_case} =
        %UseCase{}
        |> UseCase.changeset(%{key: "coding_implement", name: "Implementación"})
        |> Repo.insert()

      {:ok, binding} =
        %UseCaseModel{}
        |> UseCaseModel.changeset(%{
          router_use_case_id: use_case.id,
          target_model_id: model.id,
          effort_tier: "high"
        })
        |> Repo.insert()

      assert {:ok, log} =
               Logs.log_request(%{
                 subject_type: "user",
                 group_member_id: member.id,
                 # The alias the client sent, and the model that actually served.
                 model_requested: "router",
                 model_resolved: model.name,
                 model_id: model.id,
                 status_code: 200,
                 routed_via_router: true,
                 router_use_case_id: use_case.id,
                 router_use_case_key: "coding_implement",
                 router_use_case_model_id: binding.id,
                 router_effort_tier: "high",
                 router_decision_source: "classifier",
                 router_decision_ms: 42,
                 router_decision_cost_usd: Decimal.new("0.000123"),
                 router_baseline_model_id: model.id,
                 router_baseline_cost_usd: Decimal.new("0.001000"),
                 router_direct_access: false,
                 prompt_tokens_saved_est: 1_234
               })

      reloaded = Repo.get_by!(RequestLog, id: log.id, inserted_at: log.inserted_at)

      assert reloaded.routed_via_router
      assert reloaded.model_requested == "router"
      assert reloaded.model_resolved == model.name
      assert reloaded.model_id == model.id
      assert reloaded.router_use_case_id == use_case.id
      assert reloaded.router_use_case_key == "coding_implement"
      assert reloaded.router_use_case_model_id == binding.id
      assert reloaded.router_effort_tier == "high"
      assert reloaded.router_decision_source == "classifier"
      assert reloaded.router_decision_ms == 42
      assert Decimal.equal?(reloaded.router_decision_cost_usd, Decimal.new("0.000123"))
      assert reloaded.router_baseline_model_id == model.id
      assert Decimal.equal?(reloaded.router_baseline_cost_usd, Decimal.new("0.001"))
      assert reloaded.router_direct_access == false
      assert reloaded.prompt_tokens_saved_est == 1_234
    end

    test "a non-routed row keeps the honest defaults" do
      member = member_fixture()

      assert {:ok, log} =
               Logs.log_request(%{
                 subject_type: "user",
                 group_member_id: member.id,
                 model_requested: "glm-5.2",
                 status_code: 200
               })

      reloaded = Repo.get_by!(RequestLog, id: log.id, inserted_at: log.inserted_at)

      refute reloaded.routed_via_router
      assert reloaded.model_resolved == nil
      assert reloaded.router_direct_access == nil
      assert reloaded.prompt_tokens_saved_est == nil
    end

    test "the decision cost is NOT folded into provider_cost_usd" do
      member = member_fixture()

      assert {:ok, log} =
               Logs.log_request(%{
                 subject_type: "user",
                 group_member_id: member.id,
                 model_requested: "router",
                 status_code: 200,
                 provider_cost_usd: Decimal.new("0.010000"),
                 router_decision_cost_usd: Decimal.new("0.000200")
               })

      reloaded = Repo.get_by!(RequestLog, id: log.id, inserted_at: log.inserted_at)

      assert Decimal.equal?(reloaded.provider_cost_usd, Decimal.new("0.01"))
      assert Decimal.equal?(reloaded.router_decision_cost_usd, Decimal.new("0.0002"))
    end
  end
end
