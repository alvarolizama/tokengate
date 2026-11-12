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

  import Ecto.Query, warn: false

  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.WebhookWorker
  alias Tokengate.Repo

  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    # Idempotencia (C2): los reintentos de Oban re-ejecutan perform con el
    # MISMO job id. El pre-check es seguro porque Oban nunca ejecuta el mismo
    # job concurrentemente (los intentos son secuenciales): si ya hay fila,
    # el primer intento ya entregó webhook y broadcast — no repetirlos. El
    # índice único (oban_job_id, inserted_at) queda de respaldo durable.
    # Passing inserted_at prunes to a single partition (day) instead of
    # probing the unique index across every partition.
    if job_id && Logs.request_log_seen?(job_id, parse_inserted_at(args["inserted_at"])) do
      :ok
    else
      insert_and_deliver(job_id, args)
    end
  end

  defp insert_and_deliver(job_id, args) do
    attrs = %{
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
      inserted_at: parse_inserted_at(args["inserted_at"]),
      # Idempotencia (C2): la pareja única con `inserted_at`. NULL cuando el
      # job no tiene id (perform directo en tests) — Postgres trata NULLs
      # como distintos y el índice no los toca.
      oban_job_id: job_id
    }

    case Logs.log_request(attrs) do
      {:ok, request_log} ->
        request_log = reload_for_delivery(request_log)

        _ = WebhookWorker.dispatch(request_log)
        broadcast_new_log(request_log)
        :ok

      {:error, changeset} ->
        {:error, "request log insert failed: #{inspect(changeset.errors)}"}
    end
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
  defp reload_for_delivery(%RequestLog{id: id, inserted_at: inserted_at} = log) do
    from(rl in RequestLog,
      where: rl.id == ^id and rl.inserted_at == ^DateTime.truncate(inserted_at, :second),
      left_join: p in assoc(rl, :provider),
      left_join: s in assoc(rl, :service),
      left_join: gm in assoc(rl, :group_member),
      left_join: u in assoc(gm, :user),
      left_join: g in assoc(gm, :group),
      preload: [provider: p, service: s, group_member: {gm, user: u, group: g}]
    )
    |> Repo.one()
    |> case do
      nil ->
        # `ON CONFLICT DO NOTHING` (a duplicate (oban_job_id, inserted_at) pair)
        # leaves no row to reload. Broadcast the bare struct with the
        # association fields explicitly nil — the same shape the old
        # `Repo.preload/2` produced — so consumers' `log.provider` style reads
        # never see a `%Ecto.Association.NotLoaded{}`.
        %{log | provider: nil, service: nil, group_member: nil}

      reloaded ->
        reloaded
    end
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
