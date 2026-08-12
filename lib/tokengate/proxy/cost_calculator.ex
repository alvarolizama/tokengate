defmodule Tokengate.Proxy.CostCalculator do
  @moduledoc """
  Cost accounting for TokenGate.

  TokenGate tracks **one** cost dimension per request: `provider_cost_usd` —
  the amount the upstream charged for the request.

  ## Decision chain (first wins)

      1. Upstream-reported cost — `usage.cost` in the body or
         `x-litellm-response-cost` header. The upstream is the source of truth.
      2. Manual pricing fallback — `input_cost_per_million`,
         `cache_cost_per_million`, and `output_cost_per_million` on the
         model_provider row, multiplied by the actual token counts from the
         response usage. Only applies when the upstream is silent AND all three
         fields are set (or both input+output if cache is nil).
      3. $0 — honest fallback. We don't invent costs.

  `included` (subscription/RPM) always returns $0 regardless of any reported
  or manual cost.

  ## Manual pricing formula

      non_cached = prompt_tokens - cache_read_tokens
      cost = (non_cached × input_rate + cache_read_tokens × cache_rate
              + completion_tokens × output_rate) / 1_000_000

  `prompt_tokens` follows the OpenAI convention: it INCLUDES cached tokens
  (`UsageNormalizer` keeps the provider's raw total), so the formula
  subtracts the cached subset to price it at the cache rate.

  When `cache_cost_per_million` is nil but input+output are set, the formula
  degrades to 2 terms (all prompt tokens at input rate — overestimates slightly
  when there are cache hits, but better than $0).

  All returned values are `Decimal.t()`. The proxy/controller path forwards
  the result to the `request_logs.provider_cost_usd` column (`numeric(12,6)`).
  """

  @zero Decimal.new(0)
  @million Decimal.new(1_000_000)

  @doc """
  Computes the real provider cost for a single request.

  ## Arguments

    * `billing_mode` — `"pay_per_token"` or `"included"` from the
      `model_providers` row.
    * `provider_reported_cost` — Decimal/number/string the upstream returned
      via `usage.cost` / `usage.total_cost` / top-level `cost` (when present),
      or `nil` when the upstream doesn't report a cost.
    * `manual_pricing` — optional map with `:input_cost_per_million`,
      `:output_cost_per_million`, and `:cache_cost_per_million` (Decimal or nil).
    * `usage` — optional map with `:prompt_tokens`, `:completion_tokens`, and
      `:cache_read_tokens` (integers).

  Returns a `Decimal.t()` — always a valid Decimal. `included` always returns
  $0, regardless of any reported cost. Unknown billing modes also return $0
  defensively (never trust unreviewed input).
  """
  @spec provider_cost(String.t() | atom() | term(), term(), keyword()) :: Decimal.t()
  def provider_cost(billing_mode, reported, opts \\ [])

  def provider_cost("included", _reported, _opts), do: @zero

  def provider_cost("pay_per_token", nil, opts) do
    case Keyword.get(opts, :manual_pricing) do
      %{input_cost_per_million: %Decimal{} = inp, output_cost_per_million: %Decimal{} = out} ->
        usage = Keyword.get(opts, :usage, %{})

        case Map.get(opts[:manual_pricing], :cache_cost_per_million) do
          %Decimal{} = cache_cost ->
            manual_cost_3term(usage, inp, cache_cost, out)

          _ ->
            manual_cost_2term(usage, inp, out)
        end

      _ ->
        @zero
    end
  end

  def provider_cost("pay_per_token", %Decimal{} = reported, _opts) do
    Decimal.round(reported, 6)
  end

  def provider_cost("pay_per_token", reported, _opts) when is_number(reported) do
    reported
    |> to_string()
    |> Decimal.new()
    |> Decimal.round(6)
  end

  def provider_cost("pay_per_token", reported, _opts) when is_binary(reported) do
    case Decimal.parse(reported) do
      {decimal, ""} -> Decimal.round(decimal, 6)
      _ -> @zero
    end
  end

  def provider_cost("pay_per_token", _reported, _opts), do: @zero

  # Unknown billing mode (or anything that isn't a recognized string) → $0.
  def provider_cost(_billing_mode, _reported, _opts), do: @zero

  # 3-term formula: non_cached × input + cached × cache + completion × output
  defp manual_cost_3term(usage, input_rate, cache_rate, output_rate) do
    prompt = Decimal.new("#{Map.get(usage, :prompt_tokens, 0)}")
    cached = Decimal.new("#{Map.get(usage, :cache_read_tokens, 0)}")
    completion = Decimal.new("#{Map.get(usage, :completion_tokens, 0)}")
    non_cached = Decimal.sub(prompt, cached) |> Decimal.max(@zero)

    input_cost = non_cached |> Decimal.div(@million) |> Decimal.mult(input_rate)
    cache_cost = cached |> Decimal.div(@million) |> Decimal.mult(cache_rate)
    output_cost = completion |> Decimal.div(@million) |> Decimal.mult(output_rate)

    input_cost
    |> Decimal.add(cache_cost)
    |> Decimal.add(output_cost)
    |> Decimal.round(6)
  end

  # 2-term fallback: all prompt × input + completion × output
  defp manual_cost_2term(usage, input_rate, output_rate) do
    prompt = Decimal.new("#{Map.get(usage, :prompt_tokens, 0)}")
    completion = Decimal.new("#{Map.get(usage, :completion_tokens, 0)}")

    input_cost = prompt |> Decimal.div(@million) |> Decimal.mult(input_rate)
    output_cost = completion |> Decimal.div(@million) |> Decimal.mult(output_rate)

    input_cost
    |> Decimal.add(output_cost)
    |> Decimal.round(6)
  end
end
