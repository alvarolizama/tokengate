defmodule Tokengate.Providers.SubscriptionManager do
  @moduledoc """
  ETS-backed round-robin rotation among a provider's active subscriptions.

  The GenServer (registered as `__MODULE__`) owns two public, named ETS tables:

    * `:tokengate_sub_rotation` — `{provider_id, rotation_index}` counter
      used for round-robin selection.
    * `:tokengate_sub_usage` — `{subscription_id, count}` per-subscription
      usage counter.

  ## Concurrency model

  The GenServer only creates the tables in `init/1` and never touches them
  again directly. Every public function (`pick_subscription/1`,
  `record_usage/1`, `usage/1`, `rotate/1`, `exhaust/1`) runs **in the
  caller's process** against the public tables — rotation uses
  `:ets.update_counter/4` (atomic), usage counts use `:ets.update_counter/4`,
  and reads use `:ets.lookup_element/4` / `:ets.match/2`. This avoids a
  GenServer bottleneck on the hot path.

  The DB read inside `pick_subscription/1` and `rotate/1`
  (`Providers.active_subscriptions/1`) also happens in the caller's process,
  not in the GenServer. This is intentional: routing the DB read through the
  GenServer would serialize all provider selections on a single process.

  ## Wiring

  This module provides a `child_spec/1` so it can be added to a supervision
  tree. The parent application (`Tokengate.Application`) should add
  `Tokengate.Providers.SubscriptionManager` to its children list after this
  wave. Tests start the manager directly via `start_supervised!/1`.
  """

  use GenServer

  alias Tokengate.Providers
  alias Tokengate.Providers.Subscription

  @rotation_table :tokengate_sub_rotation
  @usage_table :tokengate_sub_usage
  @pubsub Tokengate.PubSub
  @topic "subscriptions"

  ## Public API --------------------------------------------------------------

  @doc """
  Starts the manager. The GenServer creates the ETS tables in `init/1` and
  then sits idle — all reads and writes happen in caller processes.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Picks the next subscription for `provider_id` using round-robin rotation.

  Returns `{:ok, %Subscription{}}` when an active subscription exists, or
  `{:error, :no_active_subscription}` when the provider has none.

  The rotation index is incremented atomically via `:ets.update_counter/4`
  and the subscription at `rem(idx, length)` is selected. The list of active
  subscriptions is ordered by `inserted_at` ASC.

  **This function runs entirely in the caller's process**, including the DB
  read (`Providers.active_subscriptions/1`). The GenServer only owns the
  ETS tables and never performs reads/writes on them itself.
  """
  @spec pick_subscription(binary()) :: {:ok, Subscription.t()} | {:error, :no_active_subscription}
  def pick_subscription(provider_id) do
    subs = order_active_subscriptions(provider_id)

    case subs do
      [] ->
        {:error, :no_active_subscription}

      [_ | _] ->
        count = length(subs)
        # Atomically increment the rotation counter for this provider,
        # initializing to 0 on first write. The returned value is the NEW
        # counter value, so we subtract 1 to get a 0-based index before
        # taking the modulo. First pick → counter 1 → index 0.
        idx = :ets.update_counter(@rotation_table, provider_id, {2, 1}, {provider_id, 0})
        sub = Enum.at(subs, rem(idx - 1, count))
        {:ok, sub}
    end
  end

  @doc """
  Records one usage event for `subscription_id`. Atomic ETS counter update.
  """
  @spec record_usage(binary()) :: :ok
  def record_usage(subscription_id) do
    :ets.update_counter(@usage_table, subscription_id, {2, 1}, {subscription_id, 0})
    :ok
  end

  @doc """
  Returns per-subscription usage counts for all subscriptions belonging to
  `provider_id` (including zero-count ones).

  The result is a list of maps: `[%{subscription_id: id, count: n}, ...]`.
  Subscriptions with no recorded usage appear with `count: 0`.
  """
  @spec usage(binary()) :: [%{subscription_id: binary(), count: non_neg_integer()}]
  def usage(provider_id) do
    subs = Providers.list_subscriptions() |> Enum.filter(&(&1.provider_id == provider_id))

    Enum.map(subs, fn sub ->
      count = read_usage_counter(sub.id)
      %{subscription_id: sub.id, count: count}
    end)
  end

  @doc """
  Same as `pick_subscription/1` but additionally broadcasts
  `{:subscription_rotated, provider_id, subscription_id}` on the
  `"subscriptions"` PubSub topic.
  """
  @spec rotate(binary()) :: {:ok, Subscription.t()} | {:error, :no_active_subscription}
  def rotate(provider_id) do
    case pick_subscription(provider_id) do
      {:ok, %Subscription{} = sub} ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:subscription_rotated, provider_id, sub.id})
        {:ok, sub}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Marks a subscription as exhausted.

  Sets the subscription status to `"exhausted"` via
  `Providers.update_subscription/2` and broadcasts
  `{:subscription_exhausted, subscription_id}` on the `"subscriptions"`
  PubSub topic. Exhausted subscriptions drop out of subsequent
  `pick_subscription/1` and `rotate/1` calls (filtered by
  `Providers.active_subscriptions/1`).
  """
  @spec exhaust(binary()) :: {:ok, Subscription.t()} | {:error, term()}
  def exhaust(subscription_id) do
    case Providers.get_subscription(subscription_id) do
      nil ->
        {:error, :not_found}

      %Subscription{} = sub ->
        case Providers.update_subscription(sub, %{status: "exhausted"}) do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              @pubsub,
              @topic,
              {:subscription_exhausted, subscription_id}
            )

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  ## GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_rotation_table()
    ensure_usage_table()
    {:ok, %{}}
  end

  ## Internals --------------------------------------------------------------

  defp ensure_rotation_table do
    if :ets.whereis(@rotation_table) == :undefined do
      :ets.new(@rotation_table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true
      ])
    end
  end

  defp ensure_usage_table do
    if :ets.whereis(@usage_table) == :undefined do
      :ets.new(@usage_table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true
      ])
    end
  end

  # Returns active subscriptions for `provider_id` ordered by inserted_at ASC.
  # Providers.active_subscriptions/1 does not order by inserted_at, so we sort
  # here to guarantee deterministic round-robin ordering.
  defp order_active_subscriptions(provider_id) do
    provider_id
    |> Providers.active_subscriptions()
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp read_usage_counter(subscription_id) do
    :ets.lookup_element(@usage_table, subscription_id, 2, 0)
  end
end
