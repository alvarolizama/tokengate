defmodule Tokengate.Routing.PoolsTest do
  @moduledoc """
  Pools visto por el router, sin DB: expansión del lane a un candidato por
  miembro, agrupación por lane, tope del 80%, intentos ya hechos y salud
  agregada de los candidatos.

  `async: false` porque `CredentialHealth` y `PoolCounters` son singletons del
  árbol de la app (ETS compartido): un `mark_slow` de este módulo no debe
  cruzarse con el de otro.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Providers.{Credential, CredentialPool, CredentialPoolMember, ModelProvider}
  alias Tokengate.Routing.{CredentialHealth, PoolCounters, Pools}

  setup do
    clear_health_marks()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures (structs en memoria: `Pools` no consulta la DB)
  # ---------------------------------------------------------------------------

  defp credential(id) do
    %Credential{id: id, provider: %Tokengate.Providers.Provider{id: "provider-of-#{id}"}}
  end

  defp member(credential_id) do
    %CredentialPoolMember{
      id: "member-#{credential_id}",
      credential_id: credential_id,
      credential: credential(credential_id)
    }
  end

  defp pool_lane(id, credential_ids, opts \\ []) do
    pool_id = Keyword.get(opts, :pool_id, "pool-#{id}")

    %ModelProvider{
      id: id,
      model_id: "model-1",
      pool_id: pool_id,
      pool: %CredentialPool{id: pool_id, members: Enum.map(credential_ids, &member/1)},
      # Un lane de pool no tiene credencial propia: la traen los miembros.
      credential: nil,
      priority: Keyword.get(opts, :priority, 1),
      provider_model: "upstream-model",
      enabled: true
    }
  end

  defp key_lane(id, opts \\ []) do
    credential_id = Keyword.get(opts, :credential_id, "cred-#{id}")

    %ModelProvider{
      id: id,
      model_id: "model-1",
      credential_id: credential_id,
      credential: credential(credential_id),
      priority: Keyword.get(opts, :priority, 1),
      provider_model: "upstream-model",
      enabled: true
    }
  end

  defp clear_health_marks do
    if :ets.whereis(:tokengate_credential_health) != :undefined do
      :ets.delete_all_objects(:tokengate_credential_health)
    end

    :ok
  end

  defp mark_degraded(credential_id) do
    :ok = CredentialHealth.mark_slow(credential_id)
    # `mark_slow` es cast: esperar al servidor deja la marca visible antes de
    # que `Pools.health/1` lea la tabla.
    _ = :sys.get_state(GenServer.whereis(CredentialHealth))
    :ok
  end

  # Expande los lanes y devuelve su primer grupo (los fixtures de abajo tienen
  # un solo lane salvo que se diga lo contrario).
  defp only_group(lanes), do: lanes |> Pools.expand() |> Pools.group() |> hd()

  # ---------------------------------------------------------------------------
  # expand/1
  # ---------------------------------------------------------------------------

  describe "expand/1" do
    test "materializes one copy per pool member, keeping the lane id, priority and pool" do
      lane = pool_lane("lane-a", ["cred-1", "cred-2", "cred-3"], priority: 7)

      assert [copy_1, copy_2, copy_3] = Pools.expand([lane])

      assert Enum.map([copy_1, copy_2, copy_3], & &1.credential.id) == [
               "cred-1",
               "cred-2",
               "cred-3"
             ]

      # El id del lane se conserva en todas las copias: es la clave con la que
      # se vuelve a agrupar y con la que se cuentan intentos.
      assert Enum.map([copy_1, copy_2, copy_3], & &1.id) == ["lane-a", "lane-a", "lane-a"]
      assert Enum.all?([copy_1, copy_2, copy_3], &(&1.priority == 7))
      assert Enum.all?([copy_1, copy_2, copy_3], &(&1.pool_id == "pool-lane-a"))
      # El pool sigue preloaded en la copia: la UI y el accounting no cambian.
      assert Enum.all?([copy_1, copy_2, copy_3], &(&1.pool.id == "pool-lane-a"))
    end

    test "a single-key lane is passed through untouched" do
      lane = key_lane("lane-key")

      assert Pools.expand([lane]) == [lane]
      assert hd(Pools.expand([lane])).credential.id == "cred-lane-key"
    end

    test "a pool with no members produces no candidates" do
      lane = pool_lane("lane-empty", [])

      assert Pools.expand([lane]) == []
    end

    test "a lane whose pool was not preloaded is passed through" do
      lane = %ModelProvider{
        id: "lane-unloaded",
        model_id: "model-1",
        pool_id: "pool-unloaded",
        pool: %Ecto.Association.NotLoaded{
          __field__: :pool,
          __owner__: ModelProvider,
          __cardinality__: :one
        },
        priority: 1,
        provider_model: "upstream-model",
        enabled: true
      }

      assert Pools.expand([lane]) == [lane]
    end

    test "expands every lane of a mixed list, preserving lane order" do
      pool = pool_lane("lane-pool", ["cred-a", "cred-b"])
      key = key_lane("lane-key")

      assert [%{id: "lane-pool"}, %{id: "lane-pool"}, %{id: "lane-key"}] =
               Pools.expand([pool, key])
    end
  end

  # ---------------------------------------------------------------------------
  # group/1
  # ---------------------------------------------------------------------------

  describe "group/1" do
    test "groups copies by lane id, keeping first-appearance order and the opening lane" do
      pool = pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3"])
      key = key_lane("lane-key")

      groups = Pools.group(Pools.expand([pool, key]))

      assert [pool_group, key_group] = groups
      assert %Pools.Group{id: "lane-pool"} = pool_group
      assert length(pool_group.candidates) == 3
      assert Enum.map(pool_group.candidates, & &1.credential.id) == ["cred-1", "cred-2", "cred-3"]
      # El lane del grupo es la copia que lo abrió (mismos campos del lane).
      assert pool_group.lane.id == "lane-pool"
      assert pool_group.lane.priority == 1

      assert %Pools.Group{id: "lane-key", candidates: [_only]} = key_group
    end

    test "a single-key lane is a group of one" do
      assert [%Pools.Group{id: "lane-key", candidates: [candidate]}] =
               Pools.group([key_lane("lane-key")])

      assert candidate.credential.id == "cred-lane-key"
    end

    test "keeps each lane's members when a key lane comes first" do
      key = key_lane("lane-key", priority: 1)
      pool = pool_lane("lane-pool", ["cred-a", "cred-b", "cred-c"], priority: 2)

      groups = Pools.group(Pools.expand([key, pool]))

      assert [key_group, pool_group] = groups

      assert Enum.map(key_group.candidates, & &1.credential.id) == ["cred-lane-key"]
      assert Enum.map(pool_group.candidates, & &1.credential.id) == ["cred-a", "cred-b", "cred-c"]
      assert Enum.all?(pool_group.candidates, &(&1.id == "lane-pool"))
      refute Enum.any?(key_group.candidates, &(&1.id == "lane-pool"))
    end

    test "two pools keep their own members" do
      p1 = pool_lane("lane-p1", ["c1a", "c1b"], priority: 1)
      p2 = pool_lane("lane-p2", ["c2a", "c2b"], priority: 2)

      groups = Pools.group(Pools.expand([p1, p2]))

      assert [g1, g2] = groups
      assert Enum.map(g1.candidates, & &1.credential.id) == ["c1a", "c1b"]
      assert Enum.map(g2.candidates, & &1.credential.id) == ["c2a", "c2b"]
      assert Enum.all?(g1.candidates, &(&1.id == "lane-p1"))
      assert Enum.all?(g2.candidates, &(&1.id == "lane-p2"))
    end

    test "an empty candidate list produces no groups" do
      assert Pools.group([]) == []
    end
  end

  # ---------------------------------------------------------------------------
  # cap/1 — tope por request (lo aplica la cascada en F4)
  # ---------------------------------------------------------------------------

  describe "cap/1" do
    test "is 80% of the members, floored at 1 and never above n" do
      assert Pools.cap(2) == 2
      assert Pools.cap(3) == 2
      assert Pools.cap(4) == 3
      assert Pools.cap(5) == 4
      assert Pools.cap(10) == 8
    end

    test "one member is one attempt; zero members is no attempt" do
      assert Pools.cap(1) == 1
      assert Pools.cap(0) == 0
      assert Pools.cap(-1) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # tried_in_group/2
  # ---------------------------------------------------------------------------

  describe "tried_in_group/2" do
    test "counts the pool members whose credential is excluded" do
      group = only_group([pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3"])])

      assert Pools.tried_in_group(group, ["cred-1", "cred-3"]) == 2
      assert Pools.tried_in_group(group, ["cred-2"]) == 1
    end

    test "counts the members the router already filtered out of the candidates" do
      # El router excluye credenciales ANTES de agrupar, así que el grupo que
      # llega a la cascada sólo trae el miembro que queda vivo. El conteo tiene
      # que salir del pool del lane, no de los candidatos: si no, `tried` sería
      # siempre 0 y el tope nunca se alcanzaría.
      lane = pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3", "cred-4", "cred-5"])

      remaining =
        [lane]
        |> Pools.expand()
        |> Enum.reject(&(&1.credential.id in ["cred-1", "cred-2", "cred-3", "cred-4"]))
        |> Pools.group()
        |> hd()

      assert length(remaining.candidates) == 1
      assert Pools.tried_in_group(remaining, ["cred-1", "cred-2", "cred-3", "cred-4"]) == 4
    end

    test "no exclusions (or a nil) count as zero" do
      group = only_group([pool_lane("lane-pool", ["cred-1", "cred-2"])])

      assert Pools.tried_in_group(group, []) == 0
      assert Pools.tried_in_group(group, nil) == 0
    end

    test "a single-key lane counts as one when its own credential is excluded" do
      group = only_group([key_lane("lane-key")])

      assert Pools.tried_in_group(group, ["cred-lane-key"]) == 1
      assert Pools.tried_in_group(group, ["cred-other"]) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # cap_for/1 y exhausted?/2 — el tope contado sobre los miembros del pool
  # ---------------------------------------------------------------------------

  describe "cap_for/1" do
    test "is the 80% of the pool for a pool lane" do
      group =
        only_group([pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3", "cred-4", "cred-5"])])

      assert Pools.cap_for(group) == 4
    end

    test "is one for a single-key lane" do
      assert Pools.cap_for(only_group([key_lane("lane-key")])) == 1
    end
  end

  describe "exhausted?/2" do
    test "a pool of five is exhausted with four members tried, not with three" do
      group =
        only_group([pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3", "cred-4", "cred-5"])])

      refute Pools.exhausted?(group, ["cred-1", "cred-2", "cred-3"])
      assert Pools.exhausted?(group, ["cred-1", "cred-2", "cred-3", "cred-4"])
      assert Pools.exhausted?(group, ["cred-1", "cred-2", "cred-3", "cred-4", "cred-5"])
    end

    test "an exhausted group is the one whose members the router already dropped" do
      lane = pool_lane("lane-pool", ["cred-1", "cred-2", "cred-3", "cred-4", "cred-5"])
      tried = ["cred-1", "cred-2", "cred-3", "cred-4"]

      group =
        [lane]
        |> Pools.expand()
        |> Enum.reject(&(&1.credential.id in tried))
        |> Pools.group()
        |> hd()

      # Queda un miembro sin intentar y aun así el grupo está agotado: el tope
      # es del 80%, no "hasta que no queden candidatos".
      assert Pools.tried_in_group(group, tried) == 4
      assert Pools.exhausted?(group, tried)
    end

    test "a single-key group is exhausted once its credential is excluded" do
      group = only_group([key_lane("lane-key")])

      refute Pools.exhausted?(group, [])
      assert Pools.exhausted?(group, ["cred-lane-key"])
    end
  end

  # ---------------------------------------------------------------------------
  # health/1 — salud agregada de los candidatos
  # ---------------------------------------------------------------------------

  describe "health/1" do
    test "level 0 while at least one candidate is healthy" do
      group = only_group([pool_lane("lane-pool", ["cred-1", "cred-2"])])

      mark_degraded("cred-1")

      assert Pools.health(group) == 0
    end

    test "level 1 only when every candidate is degraded" do
      group = only_group([pool_lane("lane-pool", ["cred-1", "cred-2"])])

      mark_degraded("cred-1")
      mark_degraded("cred-2")

      assert Pools.health(group) == 1
    end

    test "reads the members, not the lane's nil credential" do
      # El lane de un pool tiene `credential: nil`. El atajo de `Priority`
      # ("sin credencial = sano") mentiría aquí: la salud sale de los miembros.
      lane = pool_lane("lane-pool", ["cred-1", "cred-2"])
      assert lane.credential == nil

      group = only_group([lane])

      mark_degraded("cred-1")

      # Todavía hay un miembro sano: el grupo está sano aunque el lane no tenga
      # credencial propia.
      assert Pools.health(group) == 0

      mark_degraded("cred-2")
      assert Pools.health(group) == 1
    end

    test "a single-key group follows its own credential" do
      group = only_group([key_lane("lane-key")])

      assert Pools.health(group) == 0

      mark_degraded("cred-lane-key")
      assert Pools.health(group) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # PoolCounters — fase de la rotación
  # ---------------------------------------------------------------------------

  describe "PoolCounters.next_start/2" do
    test "advances one step per request and wraps inside the pool" do
      lane_id = "lane-counter-#{System.unique_integer([:positive])}"

      starts = Enum.map(1..4, fn _ -> PoolCounters.next_start(lane_id, 3) end)

      assert Enum.all?(starts, &(&1 in 0..2))
      # Tres posiciones distintas en cuatro llamadas: la cuarta repite la
      # primera, así que la rotación es uniforme y sin saltos.
      assert starts |> Enum.uniq() |> length() == 3
      assert List.last(starts) == List.first(starts)
    end

    test "keeps one counter per lane" do
      lane_a = "lane-counter-a-#{System.unique_integer([:positive])}"
      lane_b = "lane-counter-b-#{System.unique_integer([:positive])}"

      _ = PoolCounters.next_start(lane_a, 5)
      _ = PoolCounters.next_start(lane_a, 5)

      # El contador de `lane_b` arranca de cero: no comparte fase con `lane_a`.
      assert PoolCounters.next_start(lane_b, 5) == 1
    end

    test "returns 0 when there is nothing to rotate (n <= 0)" do
      lane_id = "lane-counter-empty-#{System.unique_integer([:positive])}"

      assert PoolCounters.next_start(lane_id, 0) == 0
      assert PoolCounters.next_start(lane_id, -2) == 0
    end
  end
end
