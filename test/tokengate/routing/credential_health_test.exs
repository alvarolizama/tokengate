defmodule Tokengate.Routing.CredentialHealthTest do
  @moduledoc """
  Tests for Tokengate.Routing.CredentialHealth — ETS soft health tracking.

  `async: false` because the ETS table (`:tokengate_credential_health`) is a
  named singleton; concurrent tests would clobber each other's marks. Each
  test uses a unique credential id via `System.unique_integer/0`.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Routing.CredentialHealth

  @table :tokengate_credential_health

  setup do
    pid = Process.whereis(CredentialHealth) || start_supervised!(CredentialHealth)
    _ = :sys.get_state(pid)

    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    {:ok, %{}}
  end

  defp unique_id do
    "cred-#{System.unique_integer([:positive])}"
  end

  describe "mark_slow/1 and degraded?/1" do
    test "a credential starts healthy" do
      id = unique_id()
      refute CredentialHealth.degraded?(id)
    end

    test "mark_slow degrades the credential" do
      id = unique_id()
      assert :ok = CredentialHealth.mark_slow(id)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))

      assert CredentialHealth.degraded?(id)
    end

    test "mark_healthy clears the degradation" do
      id = unique_id()
      :ok = CredentialHealth.mark_slow(id)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      assert CredentialHealth.degraded?(id)

      :ok = CredentialHealth.mark_healthy(id)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      refute CredentialHealth.degraded?(id)
    end

    test "degraded credentials are independent" do
      id_a = unique_id()
      id_b = unique_id()

      :ok = CredentialHealth.mark_slow(id_a)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))

      assert CredentialHealth.degraded?(id_a)
      refute CredentialHealth.degraded?(id_b)
    end
  end

  describe "record_success/2" do
    test "slow success degrades, fast success heals" do
      id = unique_id()
      threshold = CredentialHealth.slow_threshold_ms()

      # Fast success: stays healthy.
      :ok = CredentialHealth.record_success(id, threshold - 1)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      refute CredentialHealth.degraded?(id)

      # Slow success: degrades.
      :ok = CredentialHealth.record_success(id, threshold + 1)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      assert CredentialHealth.degraded?(id)

      # Fast success again: heals.
      :ok = CredentialHealth.record_success(id, threshold - 1)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      refute CredentialHealth.degraded?(id)
    end
  end

  describe "penalty expiry" do
    test "expired marks are treated as healthy and lazily cleared" do
      id = unique_id()
      :ok = CredentialHealth.mark_slow(id)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      assert CredentialHealth.degraded?(id)

      # Backdate the mark beyond the penalty window.
      penalty = CredentialHealth.slow_penalty_ms()
      [{^id, degraded_since}] = :ets.lookup(@table, id)
      :ets.insert(@table, {id, degraded_since - penalty - 1})

      # Read: expired → healthy, and the entry is cleared lazily.
      refute CredentialHealth.degraded?(id)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))
      assert :ets.lookup(@table, id) == []
    end
  end

  describe "clear_all/0" do
    test "drops every mark" do
      id_a = unique_id()
      id_b = unique_id()
      :ok = CredentialHealth.mark_slow(id_a)
      :ok = CredentialHealth.mark_slow(id_b)
      _ = :sys.get_state(GenServer.whereis(CredentialHealth))

      assert :ok = CredentialHealth.clear_all()

      refute CredentialHealth.degraded?(id_a)
      refute CredentialHealth.degraded?(id_b)
    end
  end
end
