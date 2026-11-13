defmodule Tokengate.BudgetsSubjectHistoryTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Budgets, Logs}

  test "monthly real spend belongs to user_id, even after the membership is deleted" do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "history-#{unique}@example.com",
        name: "Historical Subject",
        password: "ValidPassword123"
      })

    {:ok, group} = Accounts.create_group(%{name: "History #{unique}"})
    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "history-model",
        status_code: 200,
        prompt_tokens: 12,
        completion_tokens: 4,
        cost_usd: Decimal.new("7.125000"),
        latency_ms: 500,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    before = Budgets.spend_by_user("Etc/UTC")[user.id]
    assert Decimal.equal?(before.real_monthly_usd, Decimal.new("7.125000"))

    assert {:ok, _} = Accounts.delete_group_member(member)

    after_rotation = Budgets.spend_by_user("Etc/UTC")[user.id]
    assert after_rotation.real_monthly_usd == before.real_monthly_usd

    # Limit-attributed and total real spend remain separate: both are reported,
    # and neither is re-keyed to the deleted group_member row.
    assert Decimal.equal?(after_rotation.monthly_usd, Decimal.new("7.125000"))
    assert Decimal.equal?(after_rotation.daily_usd, Decimal.new(0))
    assert after_rotation.exhausted?
  end
end
