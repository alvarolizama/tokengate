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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    attrs = %{
      team_member_id: args["team_member_id"],
      provider_id: args["provider_id"],
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
      streaming: args["streaming"] || false
    }

    case Logs.log_request(attrs) do
      {:ok, request_log} ->
        _ = WebhookWorker.dispatch(request_log)
        :ok

      {:error, changeset} ->
        {:error, "request log insert failed: #{inspect(changeset.errors)}"}
    end
  end
end
