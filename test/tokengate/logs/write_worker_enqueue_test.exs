defmodule Tokengate.Logs.WriteWorkerEnqueueTest do
  @moduledoc """
  `WriteWorker.enqueue/3` — the durable enqueue and its last-resort backup.

  `Oban.insert/1` failing used to leave only a log line behind: the request
  stayed invisible to spend reports even though the collector counted it. The
  fallback inserts the SAME row synchronously, so a request is never lost. The
  third argument injects a failing inserter (`Oban.insert/1` in production) —
  a saturated pool cannot be reproduced deterministically in the suite.
  """

  use Tokengate.DataCase, async: true
  use Oban.Testing, repo: Tokengate.Repo

  import ExUnit.CaptureLog

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Logs.WriteWorker

  describe "enqueue/3" do
    test "a successful enqueue leaves the job for the worker (no backup row)" do
      group_member = group_member_fixture()
      args = log_args(group_member)

      assert :ok = WriteWorker.enqueue(WriteWorker.new(args), context())
      assert_enqueued(worker: WriteWorker)

      assert [] == Logs.list_logs(%{group_member_id: group_member.id})
    end

    test "a failed enqueue persists the same row synchronously (no lost request)" do
      group_member = group_member_fixture()
      args = log_args(group_member)
      failing = fn _job -> {:error, :pool_saturated} end

      log =
        capture_log(fn ->
          assert :ok = WriteWorker.enqueue(WriteWorker.new(args), context(), failing)
        end)

      assert log =~ "durable request log enqueue failed"
      assert log =~ "pool_saturated"
      assert log =~ "persisted by fallback insert"

      [row] = Logs.list_logs(%{group_member_id: group_member.id})

      # The accounting row is identical to the one the worker would write:
      # same subject, cost, tokens, status and partition timestamp. No
      # `oban_job_id` — only an enqueued job knows it.
      assert row.oban_job_id == nil
      assert row.status_code == 200
      assert row.model_requested == args["model_requested"]
      assert row.prompt_tokens == args["prompt_tokens"]
      assert row.completion_tokens == args["completion_tokens"]
      assert row.cache_hit == true
      assert Decimal.equal?(row.provider_cost_usd, Decimal.new("0.000150"))
      assert DateTime.compare(row.inserted_at, parse!(args["inserted_at"])) == :eq
    end

    test "when the backup insert also fails, enqueue reports :error without raising" do
      # No subject: `Logs.log_request/1` rejects it, so both the enqueue and
      # the fallback fail. The response path must survive.
      args = %{
        "model_requested" => "deepseek-chat",
        "subject_type" => "user",
        "inserted_at" => "2026-11-13T03:00:00Z"
      }

      failing = fn _job -> {:error, :pool_saturated} end

      log =
        capture_log(fn ->
          assert :error = WriteWorker.enqueue(WriteWorker.new(args), context(), failing)
        end)

      assert log =~ "durable request log enqueue failed"
      assert log =~ "fallback insert failed"

      assert Repo.aggregate(RequestLog, :count) == 0
    end

    test "the fallback never re-prices the request (one row, upstream cost only)" do
      group_member = group_member_fixture()
      args = log_args(group_member)
      failing = fn _job -> {:error, :timeout} end

      capture_log(fn ->
        assert :ok = WriteWorker.enqueue(WriteWorker.new(args), context(), failing)
      end)

      rows =
        Repo.all(from rl in RequestLog, where: rl.group_member_id == ^group_member.id)

      # Exactly ONE row: no retry-in-process, no duplicate accounting.
      assert [row] = rows
      assert Decimal.equal?(row.provider_cost_usd, Decimal.new("0.000150"))
    end
  end

  defp context do
    %{
      model_id: "00000000-0000-0000-0000-000000000001",
      provider_id: nil,
      status: 200,
      error_reason: nil
    }
  end

  defp log_args(group_member) do
    %{
      "group_member_id" => group_member.id,
      "user_id" => group_member.user_id,
      "subject_type" => "user",
      "model_requested" => "deepseek-chat",
      "agent_type" => "cli",
      "status_code" => 200,
      "prompt_tokens" => 120,
      "completion_tokens" => 40,
      "cache_read_tokens" => 0,
      "cache_creation_tokens" => 0,
      "provider_cost_usd" => "0.000150",
      "latency_ms" => 320,
      "streaming" => false,
      "cache_hit" => true,
      "request_type" => "chat",
      "inserted_at" => "2026-11-13T03:00:00Z"
    }
  end

  defp parse!(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  defp group_member_fixture do
    {:ok, group} = Accounts.create_group(%{name: "Enqueue #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "enqueue#{System.unique_integer([:positive])}@example.com",
        "name" => "Enqueue User",
        "password" => "ValidPassword123"
      })

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    member
  end
end
