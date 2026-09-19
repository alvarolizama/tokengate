defmodule Tokengate.Proxy.CostCalculator do
  @moduledoc """
  Cost accounting for TokenGate.

  TokenGate tracks **one** cost dimension per request: `provider_cost_usd` —
  the amount the upstream charged for the request.

  ## Decision chain (first wins)

      1. Upstream-reported cost — `usage.cost` in the body or
         `x-litellm-response-cost` header. The upstream is the source of truth.
      2. Manual pricing fallback, in the unit the LANE declared
         (`model_providers.pricing_unit`):
           * **token units** (`per_1m_tokens`, `per_1k_tokens`) —
             `input_cost_per_million`, `cache_cost_per_million` and
             `output_cost_per_million` multiplied by the token counts. Only
             applies when the upstream is silent AND the rates are set (input
             + output at least).
           * **any other unit** (`per_image`, `per_second`, `per_minute`,
             `per_1k_characters`, `per_megapixel`, `per_request`) —
             `unit_cost` multiplied by the billable quantity of the call
             (`ServiceUsage.quantities/3`). This is what lets image, video,
             music, tts and stt be priced at all, since their unit is not a
             token.
      3. $0 — honest fallback. We don't invent costs.

  Billing surface plays no part: a subscription provider is priced by the
  same chain as any other. If the upstream reports a cost, it is recorded;
  if it stays silent and there is no manual pricing, the cost is $0.

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

  alias Tokengate.Providers.Pricing

  @zero Decimal.new(0)
  @million Decimal.new(1_000_000)

  @doc """
  Computes the real provider cost for a single request.

  ## Arguments

    * `provider_reported_cost` — Decimal/number/string the upstream returned
      via `usage.cost` / top-level `cost` (when present), or `nil` when the
      upstream doesn't report a cost.
    * `manual_pricing` — optional map with `:input_cost_per_million`,
      `:output_cost_per_million`, and `:cache_cost_per_million` (Decimal or nil).
    * `usage` — optional map with `:prompt_tokens`, `:completion_tokens`, and
      `:cache_read_tokens` (integers).

  Returns a `Decimal.t()` — always a valid Decimal. An unparseable reported
  cost degrades to $0 (never trust unreviewed input).
  """
  @spec provider_cost(term(), keyword()) :: Decimal.t()
  def provider_cost(reported, opts \\ [])

  def provider_cost(nil, opts) do
    unit = Keyword.get(opts, :pricing_unit) || Pricing.default_unit()

    if Pricing.token_unit?(unit) do
      token_pricing(Keyword.get(opts, :manual_pricing), Keyword.get(opts, :usage, %{}))
    else
      unit_pricing(unit, Keyword.get(opts, :unit_cost), Keyword.get(opts, :quantities, %{}))
    end
  end

  def provider_cost(%Decimal{} = reported, _opts) do
    Decimal.round(reported, 6)
  end

  def provider_cost(reported, _opts) when is_number(reported) do
    reported
    |> to_string()
    |> Decimal.new()
    |> Decimal.round(6)
  end

  def provider_cost(reported, _opts) when is_binary(reported) do
    case Decimal.parse(reported) do
      {decimal, ""} -> Decimal.round(decimal, 6)
      _ -> @zero
    end
  end

  # Anything else (a map, a list, a bad atom) → $0.
  def provider_cost(_reported, _opts), do: @zero

  # Token pricing: the three columns are the PARAMETERS of the token unit, so
  # this is exactly the historical formula, untouched.
  defp token_pricing(
         %{input_cost_per_million: %Decimal{} = inp, output_cost_per_million: %Decimal{} = out} =
           pricing,
         usage
       ) do
    case Map.get(pricing, :cache_cost_per_million) do
      %Decimal{} = cache_cost -> manual_cost_3term(usage, inp, cache_cost, out)
      _ -> manual_cost_2term(usage, inp, out)
    end
  end

  defp token_pricing(_pricing, _usage), do: @zero

  # Unit pricing: the lane is priced per image/second/character/…, so the cost
  # is `quantity × rate / divisor`. The quantity comes from the call itself
  # (`ServiceUsage.quantities/3`) and the unit from the lane's `pricing_unit`;
  # `per_1k_characters` is the same formula with a divisor of 1000.
  #
  # A missing rate is `$0` — we never invent a price.
  defp unit_pricing(unit, %Decimal{} = rate, quantities) do
    quantity = Map.get(quantities, unit, 0)

    if quantity == 0 do
      @zero
    else
      "#{quantity}"
      |> Decimal.new()
      |> Decimal.mult(rate)
      |> Decimal.div(Decimal.new(Pricing.divisor(unit)))
      |> Decimal.round(6)
    end
  end

  defp unit_pricing(_unit, _rate, _quantities), do: @zero

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
