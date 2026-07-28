defmodule Tokengate.Logs.InflightTest do
  @moduledoc """
  Tests for Tokengate.Logs.Inflight — the ETS registry of in-flight
  (pending) proxy requests backing the live Logs UI.

  `async: false` because the ETS table is a named singleton.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Logs.Inflight

  setup do
    pid = Process.whereis(Inflight) || start_supervised!(Inflight)
    _ = :sys.get_state(pid)

    # Limpiar la tabla entre tests
    for entry <- Inflight.list() do
      Inflight.finish_request(entry.id)
    end

    :ok
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        team_member_id: Ecto.UUID.generate(),
        user_email: "user@example.com",
        team_name: "Platform",
        model_requested: "gpt-4o",
        agent_type: "api",
        streaming: true,
        think: false,
        effort: nil,
        provider_name: "Test Provider",
        api_key_prefix: "sk-test-"
      },
      overrides
    )
  end

  describe "start_request/1" do
    test "inserta el request y lo devuelve con id y started_at" do
      entry = Inflight.start_request(attrs())

      assert is_binary(entry.id)
      assert %DateTime{} = entry.started_at
      assert entry.model_requested == "gpt-4o"

      assert [listed] = Inflight.list()
      assert listed.id == entry.id
    end

    test "broadcast :inflight_started en el topic" do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())

      entry = Inflight.start_request(attrs())

      assert_receive {:inflight_started, broadcasted}
      assert broadcasted.id == entry.id
    end
  end

  describe "finish_request/1" do
    test "elimina el request y broadcast :inflight_done" do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())

      entry = Inflight.start_request(attrs())
      assert_receive {:inflight_started, _}

      :ok = Inflight.finish_request(entry.id)

      assert Inflight.list() == []
      assert_receive {:inflight_done, id}
      assert id == entry.id
    end

    test "id desconocido es noop" do
      assert :ok = Inflight.finish_request("no-existe")
    end
  end

  describe "list/0" do
    test "ordena por started_at desc (más reciente primero)" do
      old = Inflight.start_request(attrs(%{model_requested: "old"}))
      Process.sleep(1100)
      new = Inflight.start_request(attrs(%{model_requested: "new"}))

      assert [first, second] = Inflight.list()
      assert first.id == new.id
      assert second.id == old.id
    end
  end

  describe "sweep" do
    test "elimina entradas más viejas que el TTL y broadcast done" do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())

      stale = Inflight.start_request(attrs(%{model_requested: "stale"}))
      fresh = Inflight.start_request(attrs(%{model_requested: "fresh"}))
      assert_receive {:inflight_started, _}
      assert_receive {:inflight_started, _}

      # Envejecer manualmente la entrada stale más allá del TTL
      Inflight.backdate_for_test(stale.id, Inflight.ttl_ms() + 1_000)

      send(Process.whereis(Inflight), :sweep)
      _ = :sys.get_state(Inflight)

      assert [remaining] = Inflight.list()
      assert remaining.id == fresh.id
      assert_receive {:inflight_done, id}
      assert id == stale.id
    end
  end
end
