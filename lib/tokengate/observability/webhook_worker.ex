defmodule Tokengate.Observability.WebhookWorker do
  @moduledoc """
  Oban worker that delivers OTLP/JSON telemetry payloads to observability
  destinations via HTTP webhook POST.

  ## Retry semantics

    * **2xx** → `:ok` (success, no retry).
    * **4xx** → `{:discard, reason}` — the request is malformed or the
      destination rejected it; retrying won't help.
    * **5xx / transport error** → `{:error, reason}` — Oban retries with
      exponential backoff up to `max_attempts`.

  ## HMAC signature

  Every webhook POST includes an `X-Tokengate-Signature` header with an
  HMAC-SHA256 of the request body:

      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  The `secret` is read from `Application.get_env(:tokengate, :webhook_secret,
  "tokengate-dev-secret")`.

  ## Dispatch

  `dispatch/1` is a plain function (not the worker callback) that resolves
  every destination and enqueues one `WebhookWorker` job per destination,
  batching the log ids. Los destinos son globales: no se filtran por el perfil de límites
  del request log.

  ## Idempotencia (auditoría Alto 2)

  El fan-out del `WriteWorker` se re-ejecuta en cada reintento, así que
  `dispatch/1` DEBE ser idempotente. La unicidad la da Oban en el propio
  worker: `unique: [period: :infinity, fields: [:args, :queue, :worker]]` con
  args `{destination_id, request_log_ids}` — la huella exacta de
  (destino, log). Un segundo enqueue del mismo par devuelve
  `{:ok, %Job{conflict?: true}}` y NO inserta. El período `:infinity` cubre
  toda la vida del job (available/executing/retryable/scheduled) y se libera
  al completarse o descartarse, que es justo lo que queremos: mientras el job
  exista no se duplica; cuando terminó, un dispatch posterior sí puede
  encolar (el receptor deduplica por `x-tokengate-delivery-id`).

  `Oban.insert/1` se usa SIN bang: un fallo de inserción (pool saturado,
  conexión caída) se devuelve como `{:error, reason}` para que el llamador
  reintente, en vez de lanzar y perder el fan-out del resto de destinos.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    # Fan-out idempotente por (destination_id, request_log_id): ver
    # "Idempotencia" en el moduledoc. `fields: [:args, :queue, :worker]` hashea
    # los args completos, que son exactamente ese par.
    unique: [period: :infinity, fields: [:args, :queue, :worker]]

  import Ecto.Query, warn: false
  require Logger

  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.Destination
  alias Tokengate.Observability.OtlpBuilder
  alias Tokengate.Repo

  @impl true
  def perform(%Oban.Job{
        id: job_id,
        args: %{"destination_id" => destination_id, "request_log_ids" => log_ids}
      }) do
    # `Repo.get!` moría con `Ecto.NoResultsError` cuando el destino se borraba
    # entre el dispatch y la ejecución: el job reintentaba 5 veces para volver
    # a fallar igual. Un destino borrado es terminal, no transitorio.
    case Repo.get(Destination, destination_id) do
      nil ->
        {:discard, "destination gone"}

      destination ->
        deliver(destination, log_ids, job_id)
    end
  end

  defp deliver(destination, log_ids, job_id) do
    logs =
      Repo.all(
        from rl in RequestLog,
          where: rl.id in ^log_ids,
          order_by: [asc: rl.inserted_at],
          preload: [group_member: [:user, :group]]
      )

    if logs == [] do
      {:discard, "no request logs found for ids: #{inspect(log_ids)}"}
    else
      payload = OtlpBuilder.build_payload(logs, destination)
      body = Jason.encode!(payload)
      headers = build_headers(destination, body, job_id)

      case http_post(destination.url, body, headers) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} when status in 400..499 ->
          {:discard, "webhook returned #{status}"}

        {:ok, %{status: status}} ->
          {:error, "webhook returned #{status}"}

        {:error, reason} ->
          {:error, "transport error: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Resolves every observability destination and enqueues one `WebhookWorker`
  job per destination, batching the log id.

  La observabilidad es de TODA la instalación: un webhook no filtra por perfil de límites,
  así que todo request log —con o sin miembro— se exporta a cada destino.

  Returns `{:ok, count}` where `count` is the number of jobs enqueued. The
  dispatch is idempotent per (destination, log) — a repeat returns
  `{:ok, 0}` for the pairs already queued (see "Idempotencia").

  Returns `{:ok, 0}` when no destinations are configured.

  Returns `{:error, reason}` when `Oban.insert/1` fails (the caller retries;
  the insert is safe to repeat), instead of raising and losing the fan-out.
  """
  @spec dispatch(RequestLog.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def dispatch(%RequestLog{id: log_id}) when is_binary(log_id) do
    log_id_str = to_string(log_id)

    Tokengate.Observability.list_all_destinations()
    |> Enum.reduce_while({:ok, 0}, fn destination, {:ok, count} ->
      %{destination_id: destination.id, request_log_ids: [log_id_str]}
      |> __MODULE__.new()
      |> Oban.insert()
      |> case do
        # `conflict?: true` = el par (destino, log) ya tenía job vivo: no
        # cuenta como enqueue nuevo, pero tampoco es un error.
        {:ok, %Oban.Job{conflict?: true}} ->
          {:cont, {:ok, count}}

        {:ok, _job} ->
          {:cont, {:ok, count + 1}}

        {:error, reason} ->
          Logger.warning(
            "webhook dispatch: could not enqueue for destination #{destination.id}: #{inspect(reason)}"
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  def dispatch(_request_log), do: {:ok, 0}

  # ---------------------------------------------------------------------------
  # HTTP POST via Req (preferred HTTP client per AGENTS.md)
  # ---------------------------------------------------------------------------

  defp http_post(url, body, headers) do
    Req.post(url,
      body: body,
      headers: headers,
      receive_timeout: 30_000,
      finch: Tokengate.Finch
    )
  end

  # ---------------------------------------------------------------------------
  # Headers (destination custom + content-type + HMAC signature)
  # ---------------------------------------------------------------------------

  # `x-tokengate-delivery-id` es el id del job de Oban: estable entre
  # reintentos del MISMO job, así que un receptor puede deduplicar entregas
  # (un retry tras un timeout de lectura reenvía el mismo id). Se omite cuando
  # no hay job (perform/1 invocado directo desde tests/herramientas).
  defp build_headers(destination, body, job_id) do
    custom_headers = normalize_headers(destination.headers || %{})
    signature = compute_signature(body)

    Map.merge(custom_headers, %{
      "content-type" => "application/json",
      "x-tokengate-signature" => signature
    })
    |> maybe_put_delivery_id(job_id)
    |> Enum.to_list()
  end

  defp maybe_put_delivery_id(headers, nil), do: headers

  defp maybe_put_delivery_id(headers, job_id),
    do: Map.put(headers, "x-tokengate-delivery-id", to_string(job_id))

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      Map.put(acc, String.downcase(to_string(key)), to_string(value))
    end)
  end

  defp compute_signature(body) do
    secret = Application.get_env(:tokengate, :webhook_secret, "tokengate-dev-secret")
    mac = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(mac, case: :lower)
  end
end
