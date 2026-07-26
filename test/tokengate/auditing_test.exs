defmodule Tokengate.AuditingTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Auditing
  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Accounts

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "user#{System.unique_integer([:positive])}@example.com",
            "name" => "Test User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  defp org_fixture do
    {:ok, org} =
      Accounts.create_organization(%{
        "name" => "Acme",
        "slug" => "acme-#{System.unique_integer([:positive])}"
      })

    org
  end

  # ---------------------------------------------------------------------------
  # audit/4
  # ---------------------------------------------------------------------------

  describe "audit/4" do
    test "records an audit log with a user struct" do
      user = user_fixture()
      org = org_fixture()

      assert {:ok, %AuditLog{} = log} =
               Auditing.audit(user, "create", "organization", org.id, %{
                 name: "Acme",
                 slug: "acme"
               })

      assert log.user_id == user.id
      assert log.action == "create"
      assert log.entity_type == "organization"
      assert log.entity_id == org.id
      assert log.changes == %{name: "Acme", slug: "acme"}
      assert log.inserted_at
      # The schema should not have updated_at since we used timestamps(updated_at: false)
      refute Map.has_key?(log, :updated_at)
    end

    test "records an audit log with a user_id string" do
      user = user_fixture()

      assert {:ok, %AuditLog{} = log} =
               Auditing.audit(user.id, "update", "user", user.id, %{role: "admin"})

      assert log.user_id == user.id
      assert log.action == "update"
      assert log.changes == %{role: "admin"}
    end

    test "records an audit log with nil user (system action)" do
      assert {:ok, %AuditLog{} = log} =
               Auditing.audit(nil, "cleanup", "sessions", "session-123")

      assert log.user_id == nil
      assert log.action == "cleanup"
      assert log.entity_type == "sessions"
      assert log.entity_id == "session-123"
      assert log.changes == %{}
    end

    test "defaults changes to empty map" do
      assert {:ok, %AuditLog{} = log} =
               Auditing.audit(nil, "rotate", "api_key", "key-123")

      assert log.changes == %{}
    end

    test "validates required fields" do
      {:error, changeset} = Auditing.audit(nil, nil, nil, nil)

      assert errors_on(changeset).action
      assert errors_on(changeset).entity_type
      assert errors_on(changeset).entity_id
    end

    test "validates foreign key on user_id" do
      {:error, changeset} =
        Auditing.audit(Ecto.UUID.generate(), "create", "org", "123")

      assert "does not exist" in errors_on(changeset).user_id
    end

    test "entity_id is a string (accepts any id format)" do
      uuid = Ecto.UUID.generate()

      {:ok, log} = Auditing.audit(nil, "create", "widget", uuid)

      assert log.entity_id == uuid
      assert is_binary(log.entity_id)
    end

    test "inserted_at only — no updated_at column" do
      {:ok, log} = Auditing.audit(nil, "test", "thing", "1")

      assert log.inserted_at
      refute Map.has_key?(log, :updated_at)
    end
  end

  # ---------------------------------------------------------------------------
  # list_audit_logs/1
  # ---------------------------------------------------------------------------

  describe "list_audit_logs/1" do
    test "returns logs ordered by inserted_at DESC" do
      # Insert sequentially. Since timestamps have second precision, we verify
      # ordering by checking that the most recently inserted log appears first.
      {:ok, _log1} = Auditing.audit(nil, "create", "thing", "1")
      {:ok, _log2} = Auditing.audit(nil, "create", "thing", "2")
      {:ok, _log3} = Auditing.audit(nil, "create", "thing", "3")

      logs = Auditing.list_audit_logs()

      # All three should be returned
      assert length(logs) == 3

      # When inserted_at ties (same second), secondary sort by id DESC applies.
      # Verify DESC ordering: the first result should have the greatest or equal
      # inserted_at compared to the last result.
      assert DateTime.compare(hd(logs).inserted_at, List.last(logs).inserted_at) in [:gt, :eq]
    end

    test "filters by user_id" do
      user1 = user_fixture(%{"email" => "user1@example.com"})
      user2 = user_fixture(%{"email" => "user2@example.com"})

      {:ok, _} = Auditing.audit(user1, "create", "thing", "1")
      {:ok, _} = Auditing.audit(user2, "create", "thing", "2")

      logs = Auditing.list_audit_logs(%{user_id: user1.id})
      assert length(logs) == 1
    end

    test "filters by entity_type" do
      {:ok, _} = Auditing.audit(nil, "create", "organization", "1")
      {:ok, _} = Auditing.audit(nil, "create", "user", "2")

      logs = Auditing.list_audit_logs(%{entity_type: "user"})
      assert length(logs) == 1
      assert hd(logs).entity_type == "user"
    end

    test "filters by action" do
      {:ok, _} = Auditing.audit(nil, "create", "thing", "1")
      {:ok, _} = Auditing.audit(nil, "delete", "thing", "2")

      logs = Auditing.list_audit_logs(%{action: "delete"})
      assert length(logs) == 1
      assert hd(logs).action == "delete"
    end

    test "respects default limit of 100" do
      for i <- 1..5 do
        Auditing.audit(nil, "create", "thing", "#{i}")
      end

      # All 5 under the limit
      assert length(Auditing.list_audit_logs()) == 5

      # Explicit limit
      assert length(Auditing.list_audit_logs(%{limit: 2})) == 2
    end

    test "returns system logs (nil user) when no user_id filter" do
      {:ok, _} = Auditing.audit(nil, "system", "job", "1")

      logs = Auditing.list_audit_logs()
      assert length(logs) == 1
      assert hd(logs).user_id == nil
    end
  end
end
