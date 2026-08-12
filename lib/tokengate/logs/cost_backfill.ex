defmodule Tokengate.Logs.CostBackfill do
  @moduledoc """
  Recalculates `provider_cost_usd` for past request_logs that recorded $0
  because the upstream didn't report a cost (e.g. LiteLLM streaming).

  For each affected log, joins to `model_providers` to get the manual pricing
  fields (`input_cost_per_million`, `output_cost_per_million`). When both are
  set, multiplies by the actual token counts from the log and updates the row.

  Only touches rows where:
    * `provider_cost_usd` is exactly 0
    * `model_provider_id` is not null
    * The model_provider has both pricing fields set
    * `billing_mode` is `pay_per_token`

  Returns `{updated_count, skipped_count}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Repo

  @million Decimal.new(1_000_000)
  @zero Decimal.new(0)

  @doc """
  Runs the backfill. Returns `{:ok, {updated, skipped}}`.
  """
  @spec run() :: {:ok, {non_neg_integer, non_neg_integer}}
  def run do
    rows =
      Repo.all(
        from(rl in Tokengate.Logs.RequestLog,
          join: mp in Tokengate.Providers.ModelProvider,
          on: rl.model_provider_id == mp.id,
          where:
            rl.provider_cost_usd == ^@zero and
              not is_nil(mp.input_cost_per_million) and
              not is_nil(mp.output_cost_per_million) and
              mp.billing_mode == "pay_per_token" and
              (rl.prompt_tokens > 0 or rl.completion_tokens > 0),
          select: %{
            id: rl.id,
            inserted_at: rl.inserted_at,
            prompt_tokens: rl.prompt_tokens,
            completion_tokens: rl.completion_tokens,
            input_cost: mp.input_cost_per_million,
            output_cost: mp.output_cost_per_million
          }
        )
      )

    updated =
      Enum.reduce(rows, 0, fn row, acc ->
        cost = compute_cost(row.prompt_tokens, row.completion_tokens, row.input_cost, row.output_cost)

        # Update by composite primary key (id + inserted_at for partitioned table)
        case Repo.update_all(
              from(rl in Tokengate.Logs.RequestLog,
                where:
                  rl.id == ^row.id and
                    rl.inserted_at == ^row.inserted_at
              ),
              set: [provider_cost_usd: cost]
            ) do
          {1, _} -> acc + 1
          _ -> acc
        end
      end)

    skipped = length(rows) - updated
    {:ok, {updated, skipped}}
  end

  defp compute_cost(prompt_tokens, completion_tokens, input_rate, output_rate) do
    prompt = Decimal.new("#{prompt_tokens}")
    completion = Decimal.new("#{completion_tokens}")

    input_cost =
      prompt
      |> Decimal.div(@million)
      |> Decimal.mult(input_rate)

    output_cost =
      completion
      |> Decimal.div(@million)
      |> Decimal.mult(output_rate)

    input_cost
    |> Decimal.add(output_cost)
    |> Decimal.round(6)
  end

  @doc """
  Counts how many logs are eligible for backfill (for preview display).
  """
  @spec count_eligible() :: non_neg_integer()
  def count_eligible do
    Repo.one(
      from(rl in Tokengate.Logs.RequestLog,
        join: mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id,
        where:
          rl.provider_cost_usd == ^@zero and
            not is_nil(mp.input_cost_per_million) and
            not is_nil(mp.output_cost_per_million) and
            mp.billing_mode == "pay_per_token" and
            (rl.prompt_tokens > 0 or rl.completion_tokens > 0),
        select: count(rl.id)
      )
    ) || 0
  end
end
