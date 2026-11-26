defmodule Tokengate.SmartRouter.DecisionCache do
  @moduledoc """
  A short-lived cache of classifier answers, keyed by a fingerprint of the
  exact question that was asked.

  The classifier costs money and latency, and agent traffic repeats the same
  prompt template many times. A hit skips the classifier entirely — the
  decision source becomes `decision_cache`, and the engine records a cache hit
  in `decision_meta` so S3 does not bill a call that never happened.

  ## Fingerprint

  `fingerprint/1` hashes the candidate use-case keys, the treated effort, the
  capability flags and the truncated user message. The truncated context is
  what the classifier actually sees, so two requests with different tails but
  the same head legitimately share an answer; two requests with different
  capabilities never do.

  TTL is deliberately short (default 5 minutes) and shorter than the session
  pin: the classifier's answer is only as good as the catalogue it was asked
  against.
  """

  use GenServer

  @table :tokengate_router_decisions
  @sweep_ms :timer.seconds(60)
  @default_ttl_ms :timer.minutes(5)

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The cached decision for `fingerprint`, or `nil` when absent/expired."
  @spec get(String.t()) :: map() | nil
  def get(fingerprint) when is_binary(fingerprint) do
    case :ets.lookup(@table, fingerprint) do
      [{_key, decision, expires_at}] ->
        if now() < expires_at do
          decision
        else
          :ets.delete(@table, fingerprint)
          nil
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Stores `decision` under `fingerprint` for `ttl_ms` (default 5 minutes)."
  @spec put(String.t(), map(), non_neg_integer() | nil) :: :ok
  def put(fingerprint, decision, ttl_ms \\ nil)
      when is_binary(fingerprint) and is_map(decision) do
    :ets.insert(
      @table,
      {fingerprint, decision, now() + (ttl_ms || @default_ttl_ms)}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every cached decision."
  @spec clear_all() :: :ok
  def clear_all, do: flush()

  @doc false
  # Test helper: ages an entry past its TTL without sleeping.
  def backdate_for_test(fingerprint, ms) do
    case :ets.lookup(@table, fingerprint) do
      [{key, decision, expires_at}] ->
        :ets.insert(@table, {key, decision, expires_at - ms})
        :ok

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Stable hash of the classifier's inputs (see the moduledoc)."
  @spec fingerprint(term()) :: String.t()
  def fingerprint(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.encode16(case: :lower)
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    ensure_table()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end
end
