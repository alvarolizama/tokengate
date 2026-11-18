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

  test "revoke_and_replace_api_key/1 kills the old token and serves the new one" do
    %{token: old_token} = member_with_key()

    assert %{member: _} = Accounts.resolve_auth_by_api_key(old_token)

    key =
      Tokengate.Repo.one(
        from ak in Tokengate.Accounts.ApiKey,
          where: ak.key_hash == ^Accounts.hash_api_key(old_token)
      )

    assert {:ok, _new_key, new_token} = Accounts.revoke_and_replace_api_key(key)

    # El entry viejo se tira por hash (no se sirve hasta el TTL) y el token
    # viejo ya no resuelve.
    assert :ets.lookup(ApiKeyCache.table(), key.key_hash) == []
    assert :error = Accounts.resolve_auth_by_api_key(old_token)
    assert %{member: _} = Accounts.resolve_auth_by_api_key(new_token)
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

  # Reemplaza el test viejo de degradación a los 50ms: con single-flight real
  # el waiter ya no duplica la consulta cuando el holder tarda.

  describe "single-flight" do
    test "concurrent misses on the same hash run the lookup once" do
      # Force a miss on a hash nobody else touches.
      key_hash =
        :crypto.hash(:sha256, "burst-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        Process.sleep(5)
        %{member: %{id: "member-single-flight"}}
      end

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> ApiKeyCache.fetch(key_hash, fun) end) end)
        |> Task.await_many(5_000)

      assert Enum.uniq(results) == [%{member: %{id: "member-single-flight"}}]
      assert :counters.get(call_count, 1) == 1
      # The lock is gone once the value is published.
      assert :ets.lookup(ApiKeyCache.lock_table(), key_hash) == []
      assert [{^key_hash, %{member: _}, _exp}] = :ets.lookup(ApiKeyCache.table(), key_hash)
    end

    test "invalid keys are still not cached, even under a burst" do
      key_hash =
        :crypto.hash(:sha256, "bogus-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> ApiKeyCache.fetch(key_hash, fn -> :error end) end)
        end)
        |> Task.await_many(5_000)

      assert Enum.uniq(results) == [:error]
      assert :ets.lookup(ApiKeyCache.table(), key_hash) == []
    end

    test "a waiter waits for a slow holder instead of duplicating the lookup" do
      key_hash =
        :crypto.hash(:sha256, "slow-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      test_pid = self()

      # The holder is slower than the old 50ms cap (the bug: the waiter gave up
      # and ran its own query right when the DB was saturated). With real
      # single-flight the waiter must wait and receive the holder's value. The
      # holder parks inside its lookup until the test releases it, so the
      # overlap is deterministic (no sleeps for synchronization).
      holder =
        Task.async(fn ->
          ApiKeyCache.fetch(key_hash, fn ->
            send(test_pid, :holder_holds_the_lock)

            receive do
              :release_holder -> %{member: %{id: "slow-holder"}}
            end
          end)
        end)

      assert_receive :holder_holds_the_lock, 1_000
      assert :ets.lookup(ApiKeyCache.lock_table(), key_hash) != []

      call_count = :counters.new(1, [:atomics])

      waiter =
        Task.async(fn ->
          ApiKeyCache.fetch(key_hash, fn ->
            :counters.add(call_count, 1, 1)
            %{member: %{id: "duplicado"}}
          end)
        end)

      send(holder.pid, :release_holder)

      assert %{member: %{id: "slow-holder"}} = Task.await(waiter, 5_000)
      assert %{member: %{id: "slow-holder"}} = Task.await(holder, 5_000)

      # The waiter never ran its own lookup.
      assert :counters.get(call_count, 1) == 0
    end

    test "an expired lock is taken over by exactly one waiter" do
      key_hash =
        :crypto.hash(:sha256, "expired-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      call_count = :counters.new(1, [:atomics])

      # A live holder that overran its window: its lock is already expired.
      holder = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
      expired = System.monotonic_time(:millisecond) - 1
      :ets.insert(ApiKeyCache.lock_table(), {key_hash, holder, expired})

      fun = fn ->
        :counters.add(call_count, 1, 1)
        Process.sleep(20)
        %{member: %{id: "taken-over"}}
      end

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> ApiKeyCache.fetch(key_hash, fun) end) end)
        |> Task.await_many(5_000)

      assert Enum.uniq(results) == [%{member: %{id: "taken-over"}}]
      # One takeover, one lookup: the rest waited for the winner.
      assert :counters.get(call_count, 1) == 1
      assert :ets.lookup(ApiKeyCache.lock_table(), key_hash) == []
    end
  end
end
