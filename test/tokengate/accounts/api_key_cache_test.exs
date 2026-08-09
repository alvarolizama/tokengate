defmodule Tokengate.Accounts.ApiKeyCacheTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Accounts.ApiKeyCache

  defp member_with_key do
    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Cache Team #{System.unique_integer([:positive])}",
        "default_rpm_limit" => 120,
        "default_concurrency_limit" => 10
      })

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "cache-#{System.unique_integer([:positive])}@example.com",
        "name" => "Cache User",
        "password" => "ValidPassword123"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: user.id, team_id: team.id, team_role: "user"})

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{member: member, token: token, team: team}
  end

  setup do
    ApiKeyCache.invalidate_all()
    :ok
  end

  test "resolve_auth_by_api_key/1 returns member + limits for a valid token" do
    %{member: member, token: token} = member_with_key()

    entry = Accounts.resolve_auth_by_api_key(token)

    assert %{member: resolved, limits: limits} = entry
    assert resolved.id == member.id
    assert resolved.team.id == member.team_id
    assert resolved.api_key.key_prefix == String.slice(token, 0, 8)
    assert limits.rpm_limit == 120
    assert limits.concurrency_limit == 10
  end

  test "second resolution is served from ETS (no DB)" do
    %{token: token} = member_with_key()

    first = Accounts.resolve_auth_by_api_key(token)

    key_hash = Accounts.hash_api_key(token)
    assert [{^key_hash, cached, _exp}] = :ets.lookup(ApiKeyCache.table(), key_hash)
    assert cached.member.id == first.member.id

    # Same entry back without touching the DB again.
    assert Accounts.resolve_auth_by_api_key(token).member.id == first.member.id
  end

  test "invalid tokens are not cached" do
    assert :error = Accounts.resolve_auth_by_api_key("tg-bogus-token")

    key_hash = Accounts.hash_api_key("tg-bogus-token")
    assert :ets.lookup(ApiKeyCache.table(), key_hash) == []
  end

  test "replace_api_key/1 invalidates the old token" do
    %{member: member, token: old_token} = member_with_key()

    assert %{member: _} = Accounts.resolve_auth_by_api_key(old_token)

    {:ok, _api_key, new_token} = Accounts.replace_api_key(member)

    assert :error = Accounts.resolve_auth_by_api_key(old_token)
    assert %{member: _} = Accounts.resolve_auth_by_api_key(new_token)
  end

  test "revoke_api_key/1 invalidates the cached entry" do
    %{member: member, token: token} = member_with_key()

    assert %{member: _} = Accounts.resolve_auth_by_api_key(token)

    member = Tokengate.Repo.preload(member, [:api_key])
    {:ok, _revoked} = Accounts.revoke_api_key(member.api_key)

    assert :error = Accounts.resolve_auth_by_api_key(token)
  end

  test "update_team_member/1 drops the cached entry (status/limits change)" do
    %{member: member, token: token} = member_with_key()

    assert %{member: _} = Accounts.resolve_auth_by_api_key(token)

    {:ok, _suspended} = Accounts.update_team_member(member, %{"status" => "suspended"})

    # Cache was invalidated: resolution re-queries and finds the suspended
    # membership — the plug then rejects with 403, but the entry itself is
    # still returned (status lives on the member struct).
    assert %{member: %{status: "suspended"}} = Accounts.resolve_auth_by_api_key(token)
  end

  test "update_team/2 drops entries for every member of the team" do
    %{member: member, token: token, team: team} = member_with_key()

    assert %{limits: %{rpm_limit: 120}} = Accounts.resolve_auth_by_api_key(token)

    {:ok, _team} = Accounts.update_team(team, %{"default_rpm_limit" => 999})

    assert %{limits: %{rpm_limit: 999}} = Accounts.resolve_auth_by_api_key(token)
    assert member.team_id == team.id
  end

  test "degrades to a direct DB lookup when the ETS table is gone" do
    %{token: token} = member_with_key()

    # Simulate a node whose supervision tree predates the cache (hot code
    # reload): kill the cache process and keep it dead so the table it owns
    # is destroyed. Auth resolution must keep working — uncached — instead
    # of crashing with ArgumentError.
    :ok = Supervisor.terminate_child(Tokengate.Supervisor, ApiKeyCache)

    try do
      assert :ets.whereis(ApiKeyCache.table()) == :undefined
      assert %{member: _} = Accounts.resolve_auth_by_api_key(token)
      assert :error = Accounts.resolve_auth_by_api_key("tg-bogus-token")
    after
      {:ok, _pid} = Supervisor.restart_child(Tokengate.Supervisor, ApiKeyCache)
    end
  end
end
