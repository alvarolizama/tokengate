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

  `StickyTracker` may not be running (e.g. tests in isolation). Tracker
  calls are wrapped so that any `:exit` / `:undefined` / `ArgumentError`
  is treated as a miss and selection continues without stickiness.
  """

  @behaviour Tokengate.Routing.Strategy
  alias Tokengate.Providers.ModelProvider
  alias Tokengate.Routing.CredentialHealth
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

  ## Internal ---------------------------------------------------------------

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
