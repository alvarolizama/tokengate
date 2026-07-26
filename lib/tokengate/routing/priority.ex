defmodule Tokengate.Routing.Priority do
  @moduledoc """
  Default routing strategy: priority-based, cache-aware, and sticky.

  Selection algorithm:

    1. Sort candidates by priority ASC NULLS LAST (nil priority sorts last;
       the sort is stable so original order is preserved within ties).
    2. If `opts[:api_key_hash]` is present: look up the sticky entry in
       `StickyTracker`. If the stuck `alias_provider_id` is among the
       candidates **and** satisfies `available?.(ap)`, return it immediately.
    3. Otherwise pick the first available candidate in priority order, stick
       to it (only when `opts[:api_key_hash]` is present), and return it.
    4. If no candidate is available, return `{:error, :no_available_provider}`.

  `StickyTracker` may not be running (e.g. tests in isolation). Tracker
  calls are wrapped so that any `:exit` / `:undefined` / `ArgumentError`
  is treated as a miss and selection continues without stickiness.
  """

  @behaviour Tokengate.Routing.Strategy

  alias Tokengate.Providers.AliasProvider
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

          %AliasProvider{} = ap ->
            if available?.(ap) do
              {:ok, ap}
            else
              # Stuck provider is unavailable: clear the stale sticky and
              # fall back to the next available candidate (re-sticking).
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

      %AliasProvider{} = ap ->
        sticky_put(api_key_hash, model_alias_id, ap.id)
        {:ok, ap}
    end
  end

  # Stable sort: priority ASC, nils last. Enum.sort_with is stable in
  # recent Elixir versions; we use a comparator that maps nil to a large
  # sentinel so nils sink to the bottom while preserving input order among
  # equal priorities.
  @nil_sentinel 9_999_999_999

  defp sort_by_priority(candidates) do
    Enum.sort_by(candidates, &priority_value/1, &(&1 <= &2))
  end

  defp priority_value(%AliasProvider{priority: nil}), do: @nil_sentinel
  defp priority_value(%AliasProvider{priority: p}), do: p

  defp find_candidate(candidates, id) do
    Enum.find(candidates, fn %AliasProvider{id: cid} -> cid == id end)
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

  defp sticky_put(api_key_hash, model_alias_id, alias_provider_id) do
    try do
      StickyTracker.put(api_key_hash, model_alias_id, alias_provider_id)
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
