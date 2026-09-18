defmodule Tokengate.AuditingContextTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Auditing
  alias Tokengate.Accounts
  alias Tokengate.Auditing.PartitionWorker

  defp user_fixture(attrs \\ %{}) do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "audit-#{u}@example.com",
            "name" => "Audit User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  describe "log/6 — request context" do
    test "records actor email and role from a user struct" do
      user = user_fixture(%{"global_role" => "admin"})

      assert {:ok, log} =
               Auditing.log(user, "user.create", "user", user.id, %{"email" => user.email}, %{})

      assert log.user_id == user.id
      assert log.actor_email == user.email
      assert log.actor_role == "admin"
      assert log.origin == "web"
    end

    test "records IP, user-agent, origin and target label" do
      assert {:ok, log} =
               Auditing.log(nil, "auth.login_failed", "session", "x@example.com", %{}, %{
                 ip: "203.0.113.7",
                 user_agent: "curl/8",
                 origin: "web",
                 target_label: "x@example.com"
               })

      assert log.ip == "203.0.113.7"
      assert log.user_agent == "curl/8"
      assert log.target_label == "x@example.com"
      assert log.user_id == nil
    end

    test "records the responsible actor and who they were acting as" do
      admin = user_fixture()
      target = user_fixture()

      # The web layer resolves the actor as the responsible human (the admin
      # under impersonation) and passes the impersonated user as acting_as.
      assert {:ok, log} =
               Auditing.log(admin, "model.create", "model", "m-1", %{}, %{acting_as: target})

      assert log.user_id == admin.id
      assert log.actor_email == admin.email
      assert log.acting_as_id == target.id
      assert log.acting_as_email == target.email
    end
  end

  describe "list_audit_logs/1 — filters" do
    test "filters by actor_email" do
      user = user_fixture()

      {:ok, _} = Auditing.log(user, "a", "thing", "1", %{}, %{})
      {:ok, _} = Auditing.log(nil, "a", "thing", "2", %{}, %{})

      logs = Auditing.list_audit_logs(%{actor_email: user.email})
      assert length(logs) == 1
      assert hd(logs).actor_email == user.email
    end

    test "filters by inserted_at range" do
      {:ok, _} = Auditing.log(nil, "a", "thing", "1", %{}, %{})

      now = DateTime.utc_now()

      future = Auditing.list_audit_logs(%{from: DateTime.add(now, 3600, :second)})
      assert future == []

      past = Auditing.list_audit_logs(%{from: DateTime.add(now, -3600, :second)})
      assert length(past) == 1
    end

    test "count_audit_logs matches the filtered listing" do
      {:ok, _} = Auditing.log(nil, "one", "thing", "1", %{}, %{})
      {:ok, _} = Auditing.log(nil, "two", "thing", "2", %{}, %{})

      assert Auditing.count_audit_logs(%{action: "one"}) == 1
      assert Auditing.count_audit_logs(%{}) >= 2
    end
  end

  describe "PartitionWorker.partition_name/1" do
    test "formats monthly partition names" do
      assert PartitionWorker.partition_name(~D[2026-09-01]) == "audit_logs_2026_09"
      assert PartitionWorker.partition_name(~D[2026-12-15]) == "audit_logs_2026_12"
    end
  end
end
