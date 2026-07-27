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
  all destinations for a request log's team (via the team member) and
  enqueues one `WebhookWorker` job per destination, batching the log ids.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5

  import Ecto.Query, warn: false

  alias Tokengate.Accounts.TeamMember
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.Destination
  alias Tokengate.Observability.OtlpBuilder
  alias Tokengate.Repo

  @impl true
  def perform(%Oban.Job{
        args: %{"destination_id" => destination_id, "request_log_ids" => log_ids}
      }) do
    destination = Repo.get!(Destination, destination_id)

    logs =
      Repo.all(
        from rl in RequestLog,
          where: rl.id in ^log_ids,
          order_by: [asc: rl.inserted_at],
          preload: [team_member: [:user, :team]]
      )

    if logs == [] do
      {:discard, "no request logs found for ids: #{inspect(log_ids)}"}
    else
      payload = OtlpBuilder.build_payload(logs, destination)
      body = Jason.encode!(payload)
      headers = build_headers(destination, body)

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
  Resolves all observability destinations for the request log's team (via
  the team member) and enqueues one `WebhookWorker` job per destination.

  Returns `{:ok, count}` where `count` is the number of jobs enqueued.
  Returns `{:ok, 0}` if no destinations are configured or if the request
  log has no team member.
  """
  @spec dispatch(RequestLog.t()) :: {:ok, non_neg_integer()}
  def dispatch(%RequestLog{id: log_id, team_member_id: tm_id} = _request_log)
      when is_binary(log_id) and is_binary(tm_id) do
    team_member = Repo.get(TeamMember, tm_id)
    team_id = team_member && team_member.team_id

    destinations =
      if team_id do
        Tokengate.Observability.list_destinations(team_id)
      else
        []
      end

    log_id_str = to_string(log_id)

    count =
      Enum.reduce(destinations, 0, fn destination, acc ->
        %{destination_id: destination.id, request_log_ids: [log_id_str]}
        |> __MODULE__.new()
        |> Oban.insert!()

        acc + 1
      end)

    {:ok, count}
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

  defp build_headers(destination, body) do
    custom_headers = normalize_headers(destination.headers || %{})
    signature = compute_signature(body)

    Map.merge(custom_headers, %{
      "content-type" => "application/json",
      "x-tokengate-signature" => signature
    })
    |> Enum.to_list()
  end

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
