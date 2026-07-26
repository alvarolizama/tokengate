defmodule Tokengate.Routing.RoundRobin do
  @moduledoc """
  Weighted, lock-free round-robin routing strategy backed by `:atomics`.

  One atomics counter is kept per `model_alias_id` (index 1 of a 1-element
  array). Refs are stored in a public named ETS table
  (`:tokengate_rr_counters`) and created lazily on first use. A small
  bootstrap handles the creation race with `:ets.insert_new/2`: the loser
  of the race reads the winner's ref.

  ## Selection algorithm

    1. Build a rotation list from the candidates: each candidate is repeated
       `weight` times (`nil` weight = 1, individual weight capped at 100).
       The list is rebuilt per call — it is cheap for small N and avoids
       stale-candidate caching.
    2. `i = :atomics.add_get(ref, 1, 1)` — atomically increment and get the
       new counter value.
    3. `start = rem(i, len)` — starting position in the rotation list.
    4. Scan up to `len` positions (wrapping) for the first candidate
       satisfying `available?.(candidate)`.
    5. If none is available, return `{:error, :no_available_provider}`.

  ## Properties

    * Lock-free: the only shared mutable state is the atomics counter, which
      is incremented with a single atomic fetch-and-add.
    * Weighted: a candidate with weight 2 is twice as likely to be selected
      as one with weight 1 (statistically, over many calls).
    * Skips unavailable providers transparently.
  """

  @behaviour Tokengate.Routing.Strategy

  alias Tokengate.Providers.AliasProvider

  @table :tokengate_rr_counters
  @weight_cap 100

  @impl true
  def select(candidates, opts) when is_list(candidates) and is_map(opts) do
    if candidates == [] do
      {:error, :no_available_provider}
    else
      available? = Map.get(opts, :available?, fn _ -> true end)
      model_alias_id = Map.get(opts, :model_alias_id)

      rotation = build_rotation(candidates)
      len = length(rotation)

      if len == 0 do
        {:error, :no_available_provider}
      else
        ref = get_or_create_ref(model_alias_id)
        i = :atomics.add_get(ref, 1, 1)
        start = rem(i, len)

        case scan(rotation, start, len, available?) do
          nil -> {:error, :no_available_provider}
          ap -> {:ok, ap}
        end
      end
    end
  end

  ## Rotation list ----------------------------------------------------------

  defp build_rotation(candidates) do
    candidates
    |> Enum.flat_map(fn %AliasProvider{} = ap ->
      weight = effective_weight(ap.weight)
      List.duplicate(ap, weight)
    end)
  end

  defp effective_weight(nil), do: 1
  defp effective_weight(w) when is_integer(w) and w < 1, do: 1
  defp effective_weight(w) when is_integer(w) and w > @weight_cap, do: @weight_cap
  defp effective_weight(w) when is_integer(w), do: w

  ## Scan for first available candidate starting at `start` -----------------

  defp scan(rotation, start, len, available?) do
    # Check positions start, start+1, ..., start+len-1 (mod len).
    Enum.find_value(0..(len - 1), fn offset ->
      idx = rem(start + offset, len)
      ap = Enum.at(rotation, idx)

      if ap != nil and available?.(ap) do
        ap
      else
        nil
      end
    end)
  end

  ## Atomics ref management -------------------------------------------------

  # The ETS table may be owned by a process that has since terminated (e.g.
  # a test process or a Task). We wrap every table access in a retry loop
  # so that a vanished table is transparently recreated.

  defp get_or_create_ref(model_alias_id) do
    with_table(fn ->
      case :ets.lookup(@table, model_alias_id) do
        [{_, ref}] -> ref
        [] -> create_ref_with_race(model_alias_id)
      end
    end)
  end

  defp create_ref_with_race(model_alias_id) do
    # Insert_new returns true if this process won the race (row was new),
    # false if another process already inserted it.
    ref = :atomics.new(1, [])

    case :ets.insert_new(@table, {model_alias_id, ref}) do
      true ->
        ref

      false ->
        # Lost the race: another process created the ref first. Discard
        # ours and read the winner's.
        [{_, winner_ref}] = :ets.lookup(@table, model_alias_id)
        winner_ref
    end
  end

  # Runs `fun` against the named ETS table, recreating it if the owning
  # process has died. Retries up to 10 times to handle concurrent
  # create/destroy races.
  defp with_table(fun) do
    with_table(fun, 10)
  end

  defp with_table(_fun, 0), do: raise("could not create :tokengate_rr_counters ETS table")

  defp with_table(fun, attempts) do
    ensure_table()

    try do
      fun.()
    rescue
      ArgumentError ->
        # Table was destroyed between ensure_table and the lookup.
        with_table(fun, attempts - 1)
    catch
      :error, :badarg ->
        with_table(fun, attempts - 1)
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            # Another process created the table concurrently. Spin until
            # it becomes visible, so the caller never sees a missing table.
            wait_for_table()
        end

      _ref ->
        :ok
    end
  end

  defp wait_for_table do
    case :ets.whereis(@table) do
      :undefined -> wait_for_table()
      _ref -> :ok
    end
  end
end
