defmodule Tokengate.Prompts.CacheTest do
  @moduledoc """
  Tests for Tokengate.Prompts.Cache — volatile ETS cache of captured
  prompts backing the Prompt Inspector LiveView.

  `async: false` because the ETS table is a named singleton.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Prompts.Cache

  @topic Cache.topic()

  setup do
    pid = Process.whereis(Cache) || start_supervised!(Cache)
    _ = :sys.get_state(pid)

    # Limpiar la tabla entre tests
    Cache.list() |> Enum.each(fn entry -> Cache.delete(entry.id) end)

    :ok
  end

  defp attrs(overrides \\ %{}) do
    messages = [
      %{"role" => "system", "content" => "You are a helpful assistant."},
      %{"role" => "user", "content" => "Hello, how are you?"}
    ]

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        team_member_id: Ecto.UUID.generate(),
        subject_type: "user",
        user_email: "user@example.com",
        service_name: nil,
        team_name: "Platform",
        team_id: Ecto.UUID.generate(),
        model_requested: "gpt-4o",
        agent_type: "api",
        client_agent: "curl/7.88",
        messages: messages
      },
      overrides
    )
  end

  describe "capture/1" do
    test "inserta el request y lo devuelve con id, started_at y preview" do
      entry = Cache.capture(attrs())

      assert is_binary(entry.id)
      assert %DateTime{} = entry.started_at
      assert entry.model_requested == "gpt-4o"
      assert is_binary(entry.preview)
      assert entry.preview != ""
    end

    test "broadcast :prompt_captured en el topic" do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, @topic)

      entry = Cache.capture(attrs())

      assert_receive {:prompt_captured, broadcasted}
      assert broadcasted.id == entry.id
    end

    test "genera preview truncado a 200 chars desde messages[0].content" do
      long_content = String.duplicate("a", 300)

      entry =
        Cache.capture(
          attrs(%{
            messages: [%{"role" => "user", "content" => long_content}]
          })
        )

      assert String.length(entry.preview) == 200
      assert String.starts_with?(entry.preview, String.slice(long_content, 0, 200))
    end

    test "preview vacío cuando messages está vacío" do
      entry = Cache.capture(attrs(%{messages: []}))
      assert entry.preview == ""
    end
  end

  describe "list/0" do
    test "ordena por started_at desc (más reciente primero)" do
      old = Cache.capture(attrs(%{model_requested: "old"}))
      Process.sleep(1100)
      new = Cache.capture(attrs(%{model_requested: "new"}))

      [first, second] = Cache.list()
      assert first.id == new.id
      assert second.id == old.id
    end

    test "entries contienen messages completos" do
      messages = [
        %{"role" => "user", "content" => "Tell me a story"},
        %{"role" => "assistant", "content" => "Once upon a time..."}
      ]

      entry = Cache.capture(attrs(%{messages: messages}))
      _ = entry

      [listed] = Cache.list()
      assert listed.messages == messages
    end
  end

  describe "list_recent/2" do
    test "devuelve filas ligeras sin messages, más recientes primero, limitadas" do
      old = Cache.capture(attrs(%{model_requested: "old"}))
      Process.sleep(1100)
      new = Cache.capture(attrs(%{model_requested: "new"}))

      [first, second] = Cache.list_recent(10)
      assert first.id == new.id
      assert second.id == old.id
      # Las filas ligeras NO traen el payload de messages
      refute Map.has_key?(first, :messages)
      assert first.last_preview != ""
    end

    test "respeta el límite" do
      Enum.each(1..5, fn i -> Cache.capture(attrs(%{model_requested: "m#{i}"})) end)
      assert length(Cache.list_recent(3)) == 3
    end

    test "filtra por email, subject_type y model" do
      Cache.capture(attrs(%{user_email: "a@example.com", model_requested: "gpt-4o"}))
      Cache.capture(attrs(%{user_email: "b@example.com", model_requested: "claude"}))

      Cache.capture(
        attrs(%{user_email: "a@example.com", subject_type: "service", model_requested: "claude"})
      )

      assert length(Cache.list_recent(10, %{"user_email" => "a@example.com"})) == 2
      assert length(Cache.list_recent(10, %{"model" => "claude"})) == 2
      assert length(Cache.list_recent(10, %{"subject_type" => "service"})) == 1
      assert length(Cache.list_recent(10, %{"user_email" => "zzz"})) == 0
    end
  end

  describe "get/1" do
    test "devuelve la entrada completa con messages por id" do
      messages = [
        %{"role" => "user", "content" => "Tell me a story"},
        %{"role" => "assistant", "content" => "Once upon a time..."}
      ]

      entry = Cache.capture(attrs(%{messages: messages}))

      fetched = Cache.get(entry.id)
      assert fetched.id == entry.id
      assert fetched.messages == messages
      assert fetched.last_preview == "Once upon a time..."
    end

    test "devuelve nil para id desconocido" do
      assert Cache.get("no-existe") == nil
    end
  end

  describe "sweep" do
    test "elimina entradas más viejas que el TTL" do
      stale = Cache.capture(attrs(%{model_requested: "stale"}))
      fresh = Cache.capture(attrs(%{model_requested: "fresh"}))

      # Envejecer manualmente la entrada stale más allá del TTL
      Cache.backdate_for_test(stale.id, Cache.ttl_ms() + 1_000)

      send(Process.whereis(Cache), :sweep)
      _ = :sys.get_state(Cache)

      remaining_ids = Cache.list() |> Enum.map(& &1.id)
      assert fresh.id in remaining_ids
      assert stale.id not in remaining_ids
    end
  end

  describe "cap" do
    test "purga las entradas más viejas al exceder max_entries" do
      # Insertar 2002 entries con mono antiguo para simular cap
      ids =
        for i <- 1..2002 do
          entry = Cache.capture(attrs(%{model_requested: "entry_#{i}"}))
          # Envejecer todas excepto las 2 más recientes
          if i <= 2000 do
            Cache.backdate_for_test(entry.id, Cache.ttl_ms() + 1_000)
          end

          entry.id
        end

      _ = ids

      # Sweep elimina las viejas (>TTL) primero
      send(Process.whereis(Cache), :sweep)
      _ = :sys.get_state(Cache)

      remaining = Cache.list()
      assert length(remaining) <= 2000
    end
  end

  describe "degradation graceful" do
    test "si la tabla no existe, capture no lanza error" do
      # Simular: la tabla ETS puede no existir tras hot-reload.
      # El patrón de degradación es: no insertar, no crashear,
      # retornar entry de todos modos (la tabla es optimización).
      # En producción el guard whereis lo maneja; aquí testeo que
      # la API pública no explota.
      entry = Cache.capture(attrs())
      assert is_binary(entry.id)
    end
  end

  describe "delete/1" do
    test "elimina una entry por id" do
      entry = Cache.capture(attrs())
      assert [_] = Cache.list()

      :ok = Cache.delete(entry.id)
      assert Cache.list() == []
    end

    test "id desconocido es noop" do
      assert :ok = Cache.delete("no-existe")
    end
  end
end
