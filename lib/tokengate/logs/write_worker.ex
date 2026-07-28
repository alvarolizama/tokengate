defmodule Tokengate.Logs.WriteWorker do
  @moduledoc """
  Oban worker that persists request logs off the hot path.

  The proxy hot path never touches Postgres synchronously: log entries are
  enqueued here (queue `:logs`) and written to the partitioned
  `request_logs` table asynchronously. After a successful insert the entry
  is dispatched to the organization's observability destinations via
  `Tokengate.Observability.WebhookWorker.dispatch/1`.

  Decimal fields arrive as JSON strings — the RequestLog changeset casts
  them back. Request logs NEVER contain prompt/completion content.
  """

  use Oban.Worker, queue: :logs, max_attempts: 5

  alias Tokengate.Logs
  alias Tokengate.Observability.WebhookWorker

  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    attrs = %{
      team_member_id: args["team_member_id"],
      provider_id: args["provider_id"],
      model_provider_id: args["model_provider_id"],
      model_alias_id: args["model_alias_id"],
      model_requested: args["model_requested"],
      model_responded: args["model_responded"],
      agent_type: args["agent_type"] || "unknown",
      status_code: args["status_code"],
      prompt_tokens: args["prompt_tokens"] || 0,
      completion_tokens: args["completion_tokens"] || 0,
      cost_usd: args["cost_usd"],
      provider_cost_usd: args["provider_cost_usd"],
      savings_usd: args["savings_usd"],
      estimated_cost_usd: args["estimated_cost_usd"],
      latency_ms: args["latency_ms"],
      ttft_ms: args["ttft_ms"],
      streaming: args["streaming"] || false,
      think: args["think"] || false,
      effort: args["effort"],
      inserted_at: parse_inserted_at(args["inserted_at"])
    }

    case Logs.log_request(attrs) do
      {:ok, request_log} ->
        request_log = Tokengate.Repo.preload(request_log, [team_member: [:user, :team], :provider])
        _ = WebhookWorker.dispatch(request_log)
        broadcast_new_log(request_log)
        :ok

      {:error, changeset} ->
        {:error, "request log insert failed: #{inspect(changeset.errors)}"}
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
