defmodule Tokengate.Logs.WriteWorker do
  @moduledoc """
  Oban worker that persists request logs off the hot path.

  The proxy hot path never touches Postgres synchronously: log entries are
  enqueued here (queue `:logs`) and written to the partitioned
  `request_logs` table asynchronously. After a successful insert the entry
  is dispatched to the organization's observability destinations via
  `Tokengate.Observability.WebhookWorker.dispatch/1`.

  `provider_cost_usd` arrives as a JSON string — the RequestLog changeset
  casts it back. Request logs NEVER contain prompt/completion content.
  """

  use Oban.Worker, queue: :logs, max_attempts: 5

  require Logger

  import Ecto.Query, warn: false

  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.WebhookWorker
  alias Tokengate.Repo

  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"

  @doc """
  Enqueues `job` on the `:logs` queue, falling back to a direct insert when
  the enqueue itself fails.

  `Oban.insert/1` is a plain INSERT in the caller process (Basic engine), so a
  saturated pool or a downed DB makes it return `{:error, _}` — and the job,
  with it the durable row, the webhook fan-out and the feed event, used to
  vanish behind a log line. The client already got its answer, so the response
  must not change; but the row IS the accounting record: losing it leaves the
  realtime collector counting a request that no spend/budget report can see.

  Fallback contract (no in-process retry):

    * the row is inserted synchronously via `Logs.log_request/1` with the SAME
      args — same subject, cost, tokens, `inserted_at` partition — so the
      accounting row survives;
    * the fan-out (webhooks + `logs:new` broadcast) is NOT re-run inline: that
      is Oban's job and coupling the response tail to a second delivery path
      would be a redesign. The row survives; that event is not broadcast;
    * the budget settlement already happened in the caller's `after`, so the
      fallback never re-prices the request: no phantom cost is created.

  `insert_fun` lets tests force the failure branch; production always uses
  `Oban.insert/1`.
  """
  @spec enqueue(
          Ecto.Changeset.t() | Oban.Job.t(),
          map(),
          (Ecto.Changeset.t() | Oban.Job.t() -> {:ok, Oban.Job.t()} | {:error, term()})
        ) :: :ok | :error
  def enqueue(job, context, insert_fun \\ &Oban.insert/1) do
    case insert_fun.(job) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "durable request log enqueue failed: #{inspect(reason)} " <> context_fields(context)
        )

        fallback_insert(job_args(job), context)
    end
  end

  # `WriteWorker.new/1` returns a changeset (that is what `Oban.insert/1`
  # takes), while a performed/queued job is a struct — the fallback must read
  # the same attrs from either shape.
  defp job_args(%Oban.Job{args: args}), do: args

  defp job_args(%Ecto.Changeset{} = changeset),
    do: Ecto.Changeset.get_field(changeset, :args) || %{}

  # Last-resort direct insert. Reuses the job args through `attrs_from_args/1`,
  # so the row is identical to the one the worker would have written (minus
  # `oban_job_id`, which only the enqueued job knows). Never raises: the proxy
  # tail must stay silent.
  defp fallback_insert(args, context) do
    case Logs.log_request(attrs_from_args(args)) do
      {:ok, log} ->
        Logger.warning(
          "durable request log persisted by fallback insert: id=#{log.id} " <>
            context_fields(context)
        )

        :ok

      {:error, changeset} ->
        Logger.error(
          "durable request log fallback insert failed: #{inspect(changeset.errors)} " <>
            context_fields(context)
        )

        :error
    end
  rescue
    error ->
      Logger.error(
        "durable request log fallback insert raised: #{Exception.message(error)} " <>
          context_fields(context)
      )

      :error
  end

  defp context_fields(context) do
    "model_id=#{inspect(context[:model_id])} " <>
      "provider_id=#{inspect(context[:provider_id])} " <>
      "status=#{inspect(context[:status])} " <>
      "error_reason=#{inspect(context[:error_reason])}"
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    # Idempotencia — dos garantías SEPARADAS (auditoría Alto 2):
    #
    #   1. **INSERT**: el par único (oban_job_id, inserted_at) y el
    #      `on_conflict: :nothing` de `Logs.log_request/1` hacen que un
    #      reintento nunca duplique la fila. Se mantiene intacto.
    #
    #   2. **Fan-out** (dispatch de webhooks + broadcast `{:new_log, _}`): NO
    #      se salta en el reintento. Antes había un atajo
    #      `if request_log_seen?(...) -> :ok` que asumía "si la fila existe, el
    #      primer intento ya entregó todo": falso cuando el proceso murió en el
    #      HUECO entre el insert y el dispatch (o cuando `Oban.insert` del
    #      webhook falló). Esa fila quedaba persistida y el webhook se perdía
    #      para siempre, porque el reintento se iba por el atajo.
    #
    # Por eso el reintento vuelve a correr el insert (no-op), el dispatch y el
    # broadcast. El dispatch es idempotente por (destination_id, request_log_id)
    # vía `unique` de Oban en `WebhookWorker`; el broadcast puede repetirse una
    # vez en esa ventana de crash y es inocuo: `stream_insert/4` está llaveado
    # por el id del log, así que reinsertar la misma fila actualiza el item en
    # el feed en vez de duplicarlo.
    insert_and_deliver(job_id, args)
  end

  defp insert_and_deliver(job_id, args) do
    attrs = args |> attrs_from_args() |> Map.put(:oban_job_id, job_id)

    case Logs.log_request(attrs) do
      {:ok, request_log} ->
        request_log = reload_for_delivery(request_log, job_id)

        case WebhookWorker.dispatch(request_log) do
          {:ok, _count} ->
            broadcast_new_log(request_log)
            :ok

          # `Oban.insert` puede fallar (pool saturado, conexión caída). Antes
          # era `Oban.insert!`/se ignoraba: la excepción mataba el job DESPUÉS
          # del insert y el atajo `request_log_seen?` del reintento se comía el
          # fan-out, así que el webhook no se entregaba nunca. Devolver
          # `{:error, _}` deja que Oban reintente: el insert es no-op y el
          # dispatch se reintenta (idempotente por destino+log).
          {:error, reason} ->
            {:error, "webhook dispatch failed: #{inspect(reason)}"}
        end

      {:error, changeset} ->
        {:error, "request log insert failed: #{inspect(changeset.errors)}"}
    end
  end

  # The exact `RequestLog` attrs the enqueued job carries, built once and
  # shared by the worker path and the enqueue fallback: both must write the
  # SAME row (same subject, cost, tokens and partition timestamp). The atom
  # keys matter — `Logs.log_request/1` merges an atom `:inserted_at`, so a
  # string-keyed map would raise `Ecto.CastError` (mixed keys).
  defp attrs_from_args(args) do
    %{
      group_member_id: args["group_member_id"],
      # El sujeto del gasto viaja en la fila: sin la columna, agregar por
      # usuario exigía un `join` a `group_members` que el servicio no paga.
      user_id: args["user_id"],
      service_id: args["service_id"],
      subject_type: args["subject_type"] || "user",
      provider_id: args["provider_id"],
      model_provider_id: args["model_provider_id"],
      model_id: args["model_id"],
      model_requested: args["model_requested"],
      model_responded: args["model_responded"],
      agent_type: args["agent_type"] || "unknown",
      status_code: args["status_code"],
      provider_status_code: args["provider_status_code"],
      error_reason: args["error_reason"],
      error_message: args["error_message"],
      prompt_tokens: args["prompt_tokens"] || 0,
      completion_tokens: args["completion_tokens"] || 0,
      cache_read_tokens: args["cache_read_tokens"] || 0,
      cache_creation_tokens: args["cache_creation_tokens"] || 0,
      provider_cost_usd: args["provider_cost_usd"],
      # Qué se debitó: el top-up (nuevo modelo) y, en filas viejas, la
      # suscripción (evidencia histórica). El proxy los pone en los args.
      credit_topup_id: args["credit_topup_id"],
      credit_subscription_id: args["credit_subscription_id"],
      latency_ms: args["latency_ms"],
      ttft_ms: args["ttft_ms"],
      streaming: args["streaming"] || false,
      # Durable marker for a gateway-local cache hit (nothing reached an
      # upstream): set ONLY by the cache-hit log paths.
      cache_hit: args["cache_hit"] || false,
      request_type: args["request_type"] || "chat",
      think: args["think"] || false,
      effort: args["effort"],
      # What the winning attempt sent to the wire (nil = no effort on the wire).
      effort_applied: args["effort_applied"],
      api_key_prefix: args["api_key_prefix"],
      api_key_id: args["api_key_id"],
      session_id: args["session_id"],
      credential_name: args["credential_name"],
      credential_id: args["credential_id"],
      client_agent: args["client_agent"],
      provider_key_prefix: args["provider_key_prefix"],
      inserted_at: parse_inserted_at(args["inserted_at"])
    }
  end

  # One query for every association the delivery path reads. `Repo.preload/2`
  # after the insert issued up to four extra round-trips per job; the joins
  # fetch the same data in a single statement (Ecto still builds one struct per
  # row, not one per join row).
  #
  # The preloads are ALL live on consumers — none is dead weight:
  #   * `provider`  → `Stats.provider_logo/1` on the "En vivo" feed (`logo_url`)
  #   * `service`   → `feed_who/1` for service-subject logs (`svc · <name>`)
  #   * `group_member.user.email` → `feed_who/1` identity column
  #   * `group_member.group` → Monitoring's scope filter (`group.id`)
  #   * `group_member.user/group` → `OtlpBuilder.build_identity/1`
  #     (`"<group.name> - <user.email>"`)
  #
  # `inserted_at` is a partition key: pinning it prunes the lookup to the day
  # the row was just written instead of probing every partition.
  #
  # `job_id` is the FALLBACK key: `Logs.log_request/1` inserts with
  # `on_conflict: :nothing`, and Ecto still returns `{:ok, struct}` with the
  # NEWLY generated primary key — a PHANTOM id when the row already existed.
  # Reloading by that id misses, and the old code then broadcast/dispatched a
  # log id that is nowhere in the table (the webhook receiver got a span for a
  # nonexistent request, and the retried fan-out never deduped because the
  # phantom id is fresh on every attempt). The unique key the worker actually
  # knows is (oban_job_id, inserted_at), so that is where the reload lands.
  defp reload_for_delivery(%RequestLog{id: id, inserted_at: inserted_at} = log, job_id) do
    inserted_at = DateTime.truncate(inserted_at, :second)

    with nil <- delivery_query() |> where(^by_id(id, inserted_at)) |> Repo.one(),
         nil <- delivery_query() |> where(^by_job(job_id, inserted_at)) |> Repo.one() do
      bare_for_broadcast(log)
    end
  end

  defp by_id(id, inserted_at), do: dynamic([rl], rl.id == ^id and rl.inserted_at == ^inserted_at)

  defp by_job(job_id, inserted_at) when is_integer(job_id),
    do: dynamic([rl], rl.oban_job_id == ^job_id and rl.inserted_at == ^inserted_at)

  defp by_job(_job_id, _inserted_at), do: dynamic(false)

  # `ON CONFLICT DO NOTHING` (a duplicate (oban_job_id, inserted_at) pair)
  # leaves no row to reload. Broadcast the bare struct with the association
  # fields explicitly nil — the same shape the old `Repo.preload/2` produced —
  # so consumers' `log.provider` style reads never see a
  # `%Ecto.Association.NotLoaded{}`.
  defp bare_for_broadcast(log), do: %{log | provider: nil, service: nil, group_member: nil}

  defp delivery_query do
    from(rl in RequestLog,
      left_join: p in assoc(rl, :provider),
      left_join: s in assoc(rl, :service),
      left_join: gm in assoc(rl, :group_member),
      left_join: u in assoc(gm, :user),
      left_join: g in assoc(gm, :group),
      preload: [provider: p, service: s, group_member: {gm, user: u, group: g}]
    )
  end

  defp parse_inserted_at(nil), do: nil

  defp parse_inserted_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp broadcast_new_log(log) do
    Phoenix.PubSub.broadcast(@pubsub, @logs_topic, {:new_log, log})
  end
end
