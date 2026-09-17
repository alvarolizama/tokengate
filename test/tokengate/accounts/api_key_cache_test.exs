defmodule Tokengate.Accounts.ApiKeyCacheTest do
  use Tokengate.DataCase, async: false
  alias Tokengate.Accounts
  alias Tokengate.Accounts.ApiKeyCache

  defp member_with_key do
    {:ok, group} =
      Accounts.create_group(%{
        "name" => "Cache Group #{System.unique_integer([:positive])}",
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
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{member: member, token: token, group: group, user: user}
  end

  setup do
    ApiKeyCache.invalidate_all()
    :ok
  end

  test "resolve_auth_by_api_key/1 returns member + limits for a valid token" do
    %{member: member, token: token, user: user} = member_with_key()

    entry = Accounts.resolve_auth_by_api_key(token)

    assert %{member: resolved, limits: limits} = entry
    assert resolved.id == member.id
    assert resolved.group.id == member.group_id
    # El entry lleva el dueño precargado: la regla `propio || contenedor ||
    # default` necesita las dos puntas dentro de lo cacheado.
    assert resolved.user.id == user.id
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

  test "update_group_member/1 drops the cached entry (status/limits change)" do
    %{member: member, token: token} = member_with_key()

    assert %{member: _} = Accounts.resolve_auth_by_api_key(token)

    {:ok, _suspended} = Accounts.update_group_member(member, %{"status" => "suspended"})

    # Cache was invalidated: resolution re-queries and finds the suspended
    # membership — the plug then rejects with 403, but the entry itself is
    # still returned (status lives on the member struct).
    assert %{member: %{status: "suspended"}} = Accounts.resolve_auth_by_api_key(token)
  end

  test "update_group/2 drops entries for every member of the group" do
    %{member: member, token: token, group: group} = member_with_key()

    assert %{limits: %{rpm_limit: 120}} = Accounts.resolve_auth_by_api_key(token)

    {:ok, _group} = Accounts.update_group(group, %{"default_rpm_limit" => 999})

    assert %{limits: %{rpm_limit: 999}} = Accounts.resolve_auth_by_api_key(token)
    assert member.group_id == group.id
  end

  # Gemelo del de arriba, pero editando al DUEÑO: los defaults propios del
  # usuario son el primer eslabón de `effective_limits/1`, así que editarlos
  # tiene que tumbar el entry cacheado igual que editar el perfil de límites.
  test "editing the USER drops the cached entry and the next resolve sees the new limits" do
    %{token: token, user: user} = member_with_key()

    assert %{limits: %{rpm_limit: 120, concurrency_limit: 10}} =
             Accounts.resolve_auth_by_api_key(token)

    key_hash = Accounts.hash_api_key(token)
    assert [{^key_hash, _entry, _exp}] = :ets.lookup(ApiKeyCache.table(), key_hash)

    {:ok, _user} =
      Accounts.admin_update_user(user, %{
        "default_rpm_limit" => 999,
        "default_concurrency_limit" => 42
      })

    # La entrada se fue del cache, no se sirvió la vieja.
    assert :ets.lookup(ApiKeyCache.table(), key_hash) == []

    assert %{limits: %{rpm_limit: 999, concurrency_limit: 42}} =
             Accounts.resolve_auth_by_api_key(token)
  end

  test "update_user/2 also drops the cached entry" do
    %{token: token, user: user} = member_with_key()

    assert %{limits: %{rpm_limit: 120}} = Accounts.resolve_auth_by_api_key(token)

    {:ok, _user} = Accounts.update_user(user, %{"default_rpm_limit" => 77})

    assert %{limits: %{rpm_limit: 77}} = Accounts.resolve_auth_by_api_key(token)
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
