defmodule Tokengate.Routing.Priority do
  @moduledoc """
  Default routing strategy: health- and priority-based, cache-aware, and sticky.

  Selection algorithm:

    1. Sort candidates by `{health, priority}`: healthy credentials first,
       then degraded (slow) ones. Within a level, `priority` ASC NULLS LAST
       decides; the sort is stable so original order is preserved within
       ties. A credential is "degraded" when
       `Tokengate.Routing.CredentialHealth` has a live slow mark for it.
       Billing surface does NOT rank candidates — a subscription is not
       preferred over a pay-per-token provider.
    2. If `opts[:api_key_hash]` is present: look up the sticky entry in
       `StickyTracker`. If the stuck `model_provider_id` is among the
       candidates, satisfies `available?.(ap)`, **and** is not degraded,
       return it immediately (a degraded stuck provider releases the stick
       so traffic flows back to a healthy one).
    3. Otherwise pick the first available candidate in health+priority order,
       stick to it (only when `opts[:api_key_hash]` is present), and return it.
    4. If no candidate is available, return `{:error, :no_available_provider}`.

  ## Selection by groups (credential pools)

  `select_groups/2` is the entry point for models that mount a credential pool:
  candidates arrive already expanded —one copy per pool member— and grouped by
  lane (`Tokengate.Routing.Pools.Group`). The algorithm above gains one level:

    1. Groups sort by `{health, priority, lane.id}`, where health is aggregated
       from the group's candidates. A pool whose members are all degraded sinks
       below a healthy group even if its priority is better; a single-key lane
       keeps competing on its own health.
    2. The first group with at least one available candidate wins. Inside it a
       lane with `pool_id` (N members) rotates: the start index comes from
       `PoolCounters.next_start/2`, open breakers and degraded members are
       skipped while a healthy member remains, and `StickyTracker` is neither
       read nor written — the stick pins the LANE, and the member choice happens
       after, always by rotation. A lane without `pool_id` (a group of one)
       keeps the exact `select/2` behavior, sticky included.
    3. Groups that already spent their cascade budget are skipped before the
       ranking: `opts[:exclude_ids]` (the credentials the cascade already tried,
       `:exclude_credential_ids` in the request context) feeds
       `Tokengate.Routing.Pools.exhausted?/2`. A pool of N stops at
       `max(1, round(N * 0.8))` tried members even though it may still have an
       untried one, so the attempt budget covers the next group.

  `select/2` is untouched: same signature, same return type, same algorithm.

  `StickyTracker` may not be running (e.g. tests in isolation). Tracker
  calls are wrapped so that any `:exit` / `:undefined` / `ArgumentError`
  is treated as a miss and selection continues without stickiness.
  """

  @behaviour Tokengate.Routing.Strategy
  alias Tokengate.Providers.ModelProvider
  alias Tokengate.Routing.CredentialHealth
  alias Tokengate.Routing.Pools
  alias Tokengate.Routing.PoolCounters
  alias Tokengate.Routing.StickyTracker

  @impl true
  def select(candidates, opts) when is_list(candidates) and is_map(opts) do
    available? = Map.get(opts, :available?, fn _ -> true end)
    api_key_hash = Map.get(opts, :api_key_hash)
    model_id = Map.get(opts, :model_id)

    sorted = sort_by_priority(candidates)

    cond do
      api_key_hash != nil ->
        select_with_stickiness(sorted, api_key_hash, model_id, available?)

      true ->
        select_plain(sorted, available?)
    end
  end

  @doc """
  Selects one candidate across lane groups.

  `groups` are `Tokengate.Routing.Pools.Group` structs: candidates already
  expanded (one copy per pool member) and grouped by `model_provider.id`. The
  return value is the chosen copy, so `route.model_provider.credential` is the
  credential that serves the request while `route.model_provider.id` stays the
  lane's.

  Same options as `select/2` (`:available?`, `:api_key_hash`, `:model_id`) plus
  `:exclude_ids` — the credential ids the cascade already tried. Groups that
  spent their budget (`Pools.exhausted?/2`) are skipped before the ranking, so
  an exhausted pool never swallows another attempt.
  Returns `{:error, :no_available_provider}` when no group has an available
  candidate.
  """
  @spec select_groups([Pools.Group.t()], map()) ::
          {:ok, ModelProvider.t()} | {:error, :no_available_provider}
  def select_groups(groups, opts) when is_list(groups) and is_map(opts) do
    available? = Map.get(opts, :available?, fn _ -> true end)
    api_key_hash = Map.get(opts, :api_key_hash)
    model_id = Map.get(opts, :model_id)
    exclude_ids = Map.get(opts, :exclude_ids, [])

    # El sticky de un lane de una sola key se resuelve ANTES del ranking: igual
    # que `select/2`, un stick vivo gana a la prioridad. Consultarlo dentro del
    # grupo ya elegido perdería un stick que apunta a un lane de peor prioridad.
    with :miss <- sticky_candidate(groups, api_key_hash, model_id, available?) do
      groups
      |> Enum.reject(&Pools.exhausted?(&1, exclude_ids))
      |> Enum.sort_by(&group_sort_key/1)
      |> Enum.reduce_while({:error, :no_available_provider}, fn group, _not_found ->
        case select_in_group(group, available?, api_key_hash, model_id) do
          {:ok, %ModelProvider{} = ap} -> {:halt, {:ok, ap}}
          {:error, :no_available_provider} -> {:cont, {:error, :no_available_provider}}
        end
      end)
    else
      {:ok, %ModelProvider{} = ap} -> {:ok, ap}
    end
  end

  ## Internal ---------------------------------------------------------------

  # Sticky across single-key lanes: the stick stores the LANE id and only key
  # lanes participate. Pools never read nor write it (rotation is per request),
  # and a candidate without a loaded credential is never a key lane.
  defp sticky_candidate(_groups, nil, _model_id, _available?), do: :miss

  defp sticky_candidate(groups, api_key_hash, model_id, available?) do
    case sticky_get(api_key_hash, model_id) do
      nil ->
        :miss

      stuck_id ->
        stuck_group =
          Enum.find(groups, fn %Pools.Group{lane: lane} ->
            lane.id == stuck_id and lane.pool_id == nil
          end)

        case stuck_group do
          %Pools.Group{candidates: [candidate]} ->
            if available?.(candidate) and not degraded_credential?(candidate) do
              {:ok, candidate}
            else
              # Igual que `select/2`: un stick que ya no sirve se suelta. Sin
              # esto, si el grupo ganador es un pool (que nunca toca el tracker)
              # el stick viejo sobreviviría hasta su TTL.
              sticky_clear(api_key_hash, model_id)
              :miss
            end

          _ ->
            :miss
        end
    end
  end

  # `{health, priority, tiebreak}` with the same tie-break as before for
  # single-key lanes (`credential_id`, the order the query returns). A pool lane
  # has no credential of its own, so its lane id closes the order.
  defp group_sort_key(%Pools.Group{} = group) do
    {Pools.health(group), priority_value(group.lane), group_tiebreak(group)}
  end

  defp group_tiebreak(%Pools.Group{lane: %ModelProvider{credential_id: nil, id: id}}), do: id

  defp group_tiebreak(%Pools.Group{lane: %ModelProvider{credential_id: credential_id}}),
    do: credential_id

  defp select_in_group(
         %Pools.Group{lane: lane, candidates: candidates},
         available?,
         api_key_hash,
         model_id
       ) do
    if lane.pool_id == nil do
      # Lane de una sola key: el grupo es de un candidato y se comporta
      # exactamente como antes — el sticky fija el LANE y aquí ya no hay nada
      # más que elegir.
      sorted = sort_by_priority(candidates)

      cond do
        api_key_hash != nil -> select_with_stickiness(sorted, api_key_hash, model_id, available?)
        true -> select_plain(sorted, available?)
      end
    else
      # Lane de pool: rotación por request. El sticky NO se consulta ni se
      # escribe (el stick es del lane, no del miembro) y la elección de miembro
      # es siempre por rotación, nunca por afinidad.
      select_rotating(candidates, lane.id, available?)
    end
  end

  # Rotación uniforme: se filtra primero por breaker (un miembro con el breaker
  # abierto no consume fase) y se rota sobre los sobrevivientes desde el
  # contador del lane. Los degraded se saltan mientras quede uno sano; si todos
  # los disponibles están degraded, se permite uno degraded antes que fallar el
  # request (el breaker ya dijo que están vivos).
  defp select_rotating(candidates, lane_id, available?) do
    usable =
      candidates
      |> Enum.sort_by(&credential_sort_key/1)
      |> Enum.filter(available?)

    case usable do
      [] ->
        {:error, :no_available_provider}

      _ ->
        usable
        |> rotate(PoolCounters.next_start(lane_id, length(usable)))
        |> pick_healthy_or_degraded()
    end
  end

  defp rotate(list, 0), do: list

  defp rotate(list, start) do
    {head, tail} = Enum.split(list, start)
    tail ++ head
  end

  defp pick_healthy_or_degraded(rotated) do
    case Enum.reject(rotated, &degraded_credential?/1) do
      [%ModelProvider{} = healthy | _] -> {:ok, healthy}
      [] -> pick_any(rotated)
    end
  end

  defp pick_any([%ModelProvider{} = ap | _]), do: {:ok, ap}
  defp pick_any(_none), do: {:error, :no_available_provider}

  # Orden estable de los miembros de un pool, independiente del orden en que
  # llegaron del cache: la fase la pone el contador, no Postgres.
  defp credential_sort_key(%ModelProvider{credential: %{id: id}}), do: id
  defp credential_sort_key(%ModelProvider{}), do: ""

  defp select_plain(sorted, available?) do
    case Enum.find(sorted, available?) do
      nil -> {:error, :no_available_provider}
      ap -> {:ok, ap}
    end
  end

  defp select_with_stickiness(sorted, api_key_hash, model_id, available?) do
    case sticky_get(api_key_hash, model_id) do
      nil ->
        pick_and_stick(sorted, api_key_hash, model_id, available?)

      stuck_id ->
        case find_candidate(sorted, stuck_id) do
          nil ->
            pick_and_stick(sorted, api_key_hash, model_id, available?)

          %ModelProvider{} = ap ->
            # Keep the stuck provider only while it's usable AND healthy. A
            # degraded (slow) stuck provider releases the stick so the user
            # flows back to a healthy candidate; on recovery the next request
            # re-sticks (and restores the prompt-cache affinity).
            if available?.(ap) and not degraded_credential?(ap) do
              {:ok, ap}
            else
              sticky_clear(api_key_hash, model_id)
              pick_and_stick(sorted, api_key_hash, model_id, available?)
            end
        end
    end
  end

  defp pick_and_stick(sorted, api_key_hash, model_id, available?) do
    case Enum.find(sorted, available?) do
      nil ->
        {:error, :no_available_provider}

      %ModelProvider{} = ap ->
        ttl = sticky_ttl_for(ap)
        sticky_put(api_key_hash, model_id, ap.id, ttl)
        {:ok, ap}
    end
  end

  # Stable sort by {health, priority}: a healthy credential always beats a
  # degraded (slow) one, and within a level the configured priority ASC
  # NULLS LAST decides. Billing surface does NOT participate — subscription
  # and pay-per-token providers compete on priority alone.
  #
  # Levels:
  #
  #   0 — healthy
  #   1 — degraded (slow)
  #
  # A degraded credential sinks below a healthy one regardless of its billing
  # surface or priority: a slow provider is worse than a fast one, because
  # the whole point of routing is that it serves traffic well.
  #
  # `Enum.sort_by/3` with a strict comparator is stable, so original order
  # is preserved among candidates sharing level and priority.
  @nil_sentinel 9_999_999_999

  defp sort_by_priority(candidates) do
    Enum.sort_by(candidates, &sort_key/1, fn {health_a, pri_a}, {health_b, pri_b} ->
      health_a < health_b or (health_a == health_b and pri_a <= pri_b)
    end)
  end

  defp sort_key(%ModelProvider{} = mp) do
    {health_level(mp), priority_value(mp)}
  end

  defp health_level(%ModelProvider{} = mp) do
    if degraded_credential?(mp), do: 1, else: 0
  end

  # Degradation is read from the credential's soft health mark. Candidates
  # without a loaded credential (isolated tests, hand-built structs) are
  # treated as healthy so selection falls back to priority alone.
  defp degraded_credential?(%ModelProvider{credential: %Ecto.Association.NotLoaded{}}),
    do: false

  defp degraded_credential?(%ModelProvider{credential: nil}), do: false

  defp degraded_credential?(%ModelProvider{credential: %{id: id}}),
    do: CredentialHealth.degraded?(id)

  defp priority_value(%ModelProvider{priority: nil}), do: @nil_sentinel
  defp priority_value(%ModelProvider{priority: p}), do: p

  defp find_candidate(candidates, id) do
    Enum.find(candidates, fn %ModelProvider{id: cid} -> cid == id end)
  end

  ## Safe StickyTracker wrappers -------------------------------------------
  #
  # StickyTracker may not be running in isolated tests. Any exit or
  # undefined-table error is treated as a miss.

  defp sticky_get(api_key_hash, model_id) do
    StickyTracker.get(api_key_hash, model_id)
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  # Returns the sticky TTL for a model_provider:
  #
  #   1. If the model_provider has an explicit `sticky_ttl_ms`, use it.
  #   2. Otherwise fall back to the single config default
  #      (`proxy.sticky_default_ttl_ms`, 3 min). Billing surface does not
  #      change the TTL anymore — every credential keeps prompt-cache affinity
  #      for the same window.
  #
  defp sticky_ttl_for(%ModelProvider{sticky_ttl_ms: ms}) when not is_nil(ms), do: ms

  defp sticky_ttl_for(%ModelProvider{}) do
    Application.get_env(:tokengate, :proxy, [])
    |> Keyword.get(:sticky_default_ttl_ms, 3 * 60 * 1000)
  end

  defp sticky_put(api_key_hash, model_id, model_provider_id, sticky_ttl_ms) do
    try do
      StickyTracker.put(api_key_hash, model_id, model_provider_id, sticky_ttl_ms)
    catch
      :exit, _ -> :ok
    end
  end

  defp sticky_clear(api_key_hash, model_id) do
    try do
      StickyTracker.clear(api_key_hash, model_id)
    catch
      :exit, _ -> :ok
    end
  end
end
