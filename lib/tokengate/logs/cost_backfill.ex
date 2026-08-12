defmodule Tokengate.Logs.CostBackfill do
  @moduledoc """
  Recalculates `provider_cost_usd` for request_logs using manual pricing.

  Two modes:

    * `:zero_only` — only logs where `provider_cost_usd = $0` (the original
      behaviour: fix logs that the upstream didn't report a cost for).
    * `:all` — recalculate ALL logs where the model_provider has pricing
      configured, regardless of the existing cost. Useful when pricing was
      wrong and needs to be re-applied to everything.

  For each affected log, joins to `model_providers` to get the manual pricing
  fields. When all three (input + cache + output) are set, uses the 3-term
  formula. When only input + output are set (cache is nil), uses the 2-term
  formula. The `cache_read_tokens` column is used as the cached token count.

  Only affects rows where:
    * `model_provider_id` is not null
    * `billing_mode` is `pay_per_token`
    * The model_provider has both input AND output pricing set

  Returns `{updated_count, skipped_count}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Repo

  @million Decimal.new(1_000_000)
  @zero Decimal.new(0)

  @doc """
  Runs the backfill.

  ## Options

    * `:mode` — `:zero_only` (default) or `:all`
  """
  @spec run(keyword()) :: {:ok, {non_neg_integer, non_neg_integer}}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :zero_only)

    base_query =
      from(rl in Tokengate.Logs.RequestLog,
        join: mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id,
        where:
          not is_nil(mp.input_cost_per_million) and
            not is_nil(mp.output_cost_per_million) and
            mp.billing_mode == "pay_per_token" and
            (rl.prompt_tokens > 0 or rl.completion_tokens > 0),
        select: %{
          id: rl.id,
          inserted_at: rl.inserted_at,
          prompt_tokens: rl.prompt_tokens,
          completion_tokens: rl.completion_tokens,
          cache_read_tokens: rl.cache_read_tokens,
          input_cost: mp.input_cost_per_million,
          output_cost: mp.output_cost_per_million,
          cache_cost: mp.cache_cost_per_million
        }
      )

    rows =
      Repo.all(
        case mode do
          :all ->
            base_query

          :zero_only ->
            from([rl, mp] in base_query, where: rl.provider_cost_usd == ^@zero)
        end
      )

    updated =
      Enum.reduce(rows, 0, fn row, acc ->
        cost = compute_cost(row)

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

  defp compute_cost(row) do
    prompt = Decimal.new("#{row.prompt_tokens}")
    cached = Decimal.new("#{row.cache_read_tokens || 0}")
    completion = Decimal.new("#{row.completion_tokens}")

    # 3-term if cache_cost is set, else 2-term
    if row.cache_cost != nil and %Decimal{} == row.cache_cost do
      non_cached = prompt |> Decimal.sub(cached) |> Decimal.max(@zero)

      input_cost = non_cached |> Decimal.div(@million) |> Decimal.mult(row.input_cost)
      cache_cost = cached |> Decimal.div(@million) |> Decimal.mult(row.cache_cost)
      output_cost = completion |> Decimal.div(@million) |> Decimal.mult(row.output_cost)

      input_cost
      |> Decimal.add(cache_cost)
      |> Decimal.add(output_cost)
      |> Decimal.round(6)
    else
      input_cost = prompt |> Decimal.div(@million) |> Decimal.mult(row.input_cost)
      output_cost = completion |> Decimal.div(@million) |> Decimal.mult(row.output_cost)

      input_cost
      |> Decimal.add(output_cost)
      |> Decimal.round(6)
    end
  end

  @doc """
  Counts how many logs are eligible for backfill (for preview display).
  """
  @spec count_eligible(keyword()) :: non_neg_integer()
  def count_eligible(opts \\ []) do
    mode = Keyword.get(opts, :mode, :zero_only)

    base =
      from(rl in Tokengate.Logs.RequestLog,
        join: mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id,
        where:
          not is_nil(mp.input_cost_per_million) and
            not is_nil(mp.output_cost_per_million) and
            mp.billing_mode == "pay_per_token" and
            (rl.prompt_tokens > 0 or rl.completion_tokens > 0),
        select: count(rl.id)
      )

    query =
      case mode do
        :all -> base
        :zero_only -> from([rl, mp] in base, where: rl.provider_cost_usd == ^@zero)
      end

    Repo.one(query) || 0
  end
end