defmodule Tokengate.CacheInvalidation do
  @moduledoc """
  Cross-node propagation of ETS cache invalidations.

  Every cache in this app lives in a **per-node** ETS table
  (`Tokengate.Accounts.ApiKeyCache`, `Tokengate.Cache`,
  `Tokengate.Routing.Cache`). A write handled on node A invalidated only A's
  table: the other nodes kept serving the old auth entry / exemption set /
  routing snapshot until their TTL expired (60s for auth and routing, 45s for
  exemptions). With more than one node behind the load balancer a revoked key
  or a changed limit stayed live on the *other* node for that window — the
  same staleness contract as a single node, but multiplied by the node count
  and invisible to the operator who made the change.

  This module closes that gap with the `Phoenix.PubSub` instance the app
  already runs (PG2 adapter: survives node churn, no extra dependency):

    * `dispatch/2` applies the invalidation **locally and synchronously**
      (the caller's node is never stale after the write) and broadcasts the
      same operation to every connected node.
    * The subscriber in this GenServer applies operations that arrive from
      **another node**. It never rebroadcasts, so there is no loop.

  ## Degradation

  The cache tables are optimizations, never dependencies — same for this
  module. If PubSub is not configured/running (an umbrella `iex -S mix` that
  boots only the repo, a release without distribution, a hot-reload into a
  supervision tree that predates this module) `dispatch/2` still applies the
  invalidation locally and silently skips the broadcast. Set
  `config :tokengate, :cache_invalidation_pubsub, false` to disable the
  broadcast entirely (tests that assert local behavior only).

  Cross-node delivery requires the nodes to be connected (Erlang
  distribution + `PG2`) — the same requirement `Presence` and the LiveView
  feeds already have.
  """

  use GenServer

  alias Tokengate.Accounts.ApiKeyCache
  alias Tokengate.Cache
  alias Tokengate.Routing

  @topic "tokengate:cache:invalidate"
  # Re-arming cadence: if the PubSub process restarts (supervisor crash,
  # hot upgrade) our subscription is gone. Re-subscribing is cheap and
  # idempotent, so a periodic check beats depending on a monitor of a
  # process whose name we would have to re-resolve anyway.
  @resubscribe_ms :timer.seconds(30)

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Applies `op` to `target` on this node and broadcasts it to the others.

  `target` is one of `:api_key_cache`, `:cache`, `:routing_cache`; `op` is the
  target-specific operation tuple understood by `apply_local/1` of that
  module. Always returns `:ok` — the local invalidation is best-effort by
  design (a missing table means there is nothing to invalidate).
  """
  @spec dispatch(atom(), term()) :: :ok
  def dispatch(target, op) do
    message = {__MODULE__, target, op, node()}
    broadcast(message)
    apply_message(message)
  end

  @doc false
  def topic, do: @topic

  @doc """
  Applies one operation to the local tables. Idempotent: deleting an entry
  twice is a no-op, and a missing table (owner down) is tolerated.
  """
  @spec apply_message(term()) :: :ok
  def apply_message({__MODULE__, :api_key_cache, op, _origin}), do: ApiKeyCache.apply_local(op)
  def apply_message({__MODULE__, :cache, op, _origin}), do: Cache.apply_local(op)

  def apply_message({__MODULE__, :routing_cache, op, _origin}),
    do: Routing.Cache.apply_local(op)

  def apply_message(_other), do: :ok

  # ---------------------------------------------------------------------------
  # GenServer — subscriber for remote invalidations
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    subscribe()
    Process.send_after(self(), :resubscribe, @resubscribe_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info({__MODULE__, _target, _op, origin} = message, state) do
    # The dispatching node already applied it synchronously; applying it
    # again would be harmless (the operations are idempotent) but pointless.
    if origin != node(), do: apply_message(message)
    {:noreply, state}
  end

  def handle_info(:resubscribe, state) do
    subscribe()
    Process.send_after(self(), :resubscribe, @resubscribe_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp subscribe do
    with pubsub when is_atom(pubsub) and not is_nil(pubsub) <- pubsub_name(),
         pid when is_pid(pid) <- Process.whereis(pubsub) do
      Phoenix.PubSub.subscribe(pubsub, @topic)
    end

    :ok
  rescue
    # PubSub may be mid-restart; the periodic check re-subscribes.
    _ -> :ok
  end

  defp broadcast(message) do
    with pubsub when is_atom(pubsub) and not is_nil(pubsub) <- pubsub_name(),
         pid when is_pid(pid) <- Process.whereis(pubsub) do
      Phoenix.PubSub.broadcast(pubsub, @topic, message)
    end

    :ok
  rescue
    # A failed broadcast must never break the write that triggered it: the
    # local invalidation already ran.
    _ -> :ok
  end

  defp pubsub_name do
    case Application.get_env(:tokengate, :cache_invalidation_pubsub, Tokengate.PubSub) do
      false -> nil
      nil -> nil
      name -> name
    end
  end
end
