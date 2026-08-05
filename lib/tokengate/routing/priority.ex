defmodule Tokengate.Routing.Priority do
  @moduledoc """
  Default routing strategy: tiered, priority-based, cache-aware, and sticky.

  Selection algorithm:

    1. Sort candidates by `{tier, priority}`: healthy subscription
       (`billing_mode == "included"`) providers form the top tier, degraded
       (slow) subscriptions next, then healthy pay-per-token, then degraded
       pay-per-token. Within a tier, `priority` ASC NULLS LAST decides; the
       sort is stable so original order is preserved within ties. A
       credential is "degraded" when `Tokengate.Routing.CredentialHealth`
       has a live slow mark for it.
    2. If `opts[:api_key_hash]` is present: look up the sticky entry in
       `StickyTracker`. If the stuck `model_provider_id` is among the
       candidates **and** satisfies `available?.(ap)`, return it immediately.
    3. Otherwise pick the first available candidate in tier+priority order,
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
    model_alias_id = Map.get(opts, :model_alias_id)

    sorted = sort_by_priority(candidates)

    cond do
      api_key_hash != nil ->
        select_with_stickiness(sorted, api_key_hash, model_alias_id, available?)

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

  defp select_with_stickiness(sorted, api_key_hash, model_alias_id, available?) do
    case sticky_get(api_key_hash, model_alias_id) do
      nil ->
        pick_and_stick(sorted, api_key_hash, model_alias_id, available?)

      stuck_id ->
        case find_candidate(sorted, stuck_id) do
          nil ->
            pick_and_stick(sorted, api_key_hash, model_alias_id, available?)

          %ModelProvider{} = ap ->
            # Keep the stuck provider only while it's usable AND healthy. A
            # degraded (slow) stuck provider releases the stick so the user
            # flows back to a healthy tier; on recovery the next request
            # re-sticks (and restores the prompt-cache affinity).
            if available?.(ap) and not degraded_credential?(ap) do
              {:ok, ap}
            else
              sticky_clear(api_key_hash, model_alias_id)
              pick_and_stick(sorted, api_key_hash, model_alias_id, available?)
            end
        end
    end
  end

  defp pick_and_stick(sorted, api_key_hash, model_alias_id, available?) do
    case Enum.find(sorted, available?) do
      nil ->
        {:error, :no_available_provider}

      %ModelProvider{} = ap ->
        sticky_put(api_key_hash, model_alias_id, ap.id, ap.sticky_ttl_ms)
        {:ok, ap}
    end
  end

  # Stable sort by {tier, priority}: tier ranks the candidate pool so a
  # healthy provider always beats a degraded one, and among healthy ones a
  # subscription ("included") always beats pay-per-token — regardless of raw
  # priority. Within a tier, the configured priority ASC NULLS LAST decides,
  # exactly as before. Tiers:
  #
  #   0 — healthy, billing_mode "included"   (use the paid-for subscription)
  #   1 — healthy, billing_mode "pay_per_token" (spend money, but fast)
  #   2 — degraded, billing_mode "included"  (slow subscription, last resort)
  #   3 — degraded, billing_mode "pay_per_token"
  #
  # A degraded subscription sinks BELOW a healthy pay-per-token: a slow
  # "free" provider is worse than a fast paid one, because the whole point
  # of preferring the subscription is that it serves traffic well.
  #
  # `Enum.sort_by/3` with a strict comparator is stable, so original order
  # is preserved among candidates sharing tier and priority.
  @nil_sentinel 9_999_999_999

  defp sort_by_priority(candidates) do
    Enum.sort_by(candidates, &sort_key/1, fn {tier_a, pri_a}, {tier_b, pri_b} ->
      tier_a < tier_b or (tier_a == tier_b and pri_a <= pri_b)
    end)
  end

  defp sort_key(%ModelProvider{} = mp) do
    {tier(mp), priority_value(mp)}
  end

  defp tier(%ModelProvider{} = mp) do
    degraded = degraded_credential?(mp)

    case {mp.billing_mode, degraded} do
      {"included", false} -> 0
      {"included", true} -> 2
      {_, false} -> 1
      {_, true} -> 3
    end
  end

  # Degradation is read from the credential's soft health mark. Candidates
  # without a loaded credential (isolated tests, hand-built structs) are
  # treated as healthy so selection falls back to billing_mode + priority.
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

  defp sticky_get(api_key_hash, model_alias_id) do
    StickyTracker.get(api_key_hash, model_alias_id)
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  defp sticky_put(api_key_hash, model_alias_id, model_provider_id, sticky_ttl_ms) do
    try do
      StickyTracker.put(api_key_hash, model_alias_id, model_provider_id, sticky_ttl_ms)
    catch
      :exit, _ -> :ok
    end
  end

  defp sticky_clear(api_key_hash, model_alias_id) do
    try do
      StickyTracker.clear(api_key_hash, model_alias_id)
    catch
      :exit, _ -> :ok
    end
  end
end
