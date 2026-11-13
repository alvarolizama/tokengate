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
             `input_cost_per_million`, `cache_cost_per_million`,
             `cache_write_cost_per_million` and `output_cost_per_million`
             multiplied by the token counts, divided by the unit's divisor
             (`Pricing.divisor/1`: 1M for `per_1m_tokens`, 1K for
             `per_1k_tokens`). Only applies when the upstream is silent AND the
             rates are set (input + output at least).
           * **any other unit** (`per_image`, `per_second`, `per_minute`,
             `per_1k_characters`, `per_megapixel`, `per_request`) —
             `unit_cost` multiplied by the billable quantity of the call
             (`ServiceUsage.quantities/3`). This is what lets image,
             tts and stt be priced at all, since their unit is not a
             token.
      3. $0 — honest fallback. We don't invent costs.

  Billing surface plays no part: a subscription provider is priced by the
  same chain as any other. If the upstream reports a cost, it is recorded;
  if it stays silent and there is no manual pricing, the cost is $0.

  ## Manual pricing formula

      divisor     = Pricing.divisor(pricing_unit)   # 1_000_000 or 1_000
      non_cached  = max(prompt_tokens - cache_read_tokens, 0)
      cost = (non_cached × input_rate
              + cache_read_tokens × cache_rate
              + cache_creation_tokens × cache_write_rate
              + completion_tokens × output_rate) / divisor

  `prompt_tokens` follows the OpenAI convention: it INCLUDES cached tokens
  (`UsageNormalizer` keeps the provider's raw total), so the formula
  subtracts the cached subset to price it at the cache rate.

  **Cache writes are additive, never subtracted.** `cache_creation_tokens`
  is a separate counter in the normalized usage — the provider reports the
  tokens it wrote into the cache, not a subset of `prompt_tokens` — so the
  write term is added on top. We do NOT subtract it from the prompt: there
  is no declared "creation ⊆ prompt" invariant to rely on, and assuming one
  would silently under-charge cache hits. When the upstream folds writes
  into the prompt, the overcount is bounded by the write rate and the
  upstream-reported cost still wins.

  Fallbacks, in this order:

    * `cache_cost_per_million` nil but input+output set → 2 terms (all prompt
      tokens at the input rate; overestimates slightly on cache hits, but
      better than $0).
    * `cache_write_cost_per_million` nil or `cache_creation_tokens == 0` →
      the write term is omitted (the historical 2/3-term formula, unchanged).

  All returned values are `Decimal.t()`. The proxy/controller path forwards
  the result to the `request_logs.provider_cost_usd` column (`numeric(12,6)`).
  """

  alias Tokengate.Providers.Pricing

  @zero Decimal.new(0)

  @doc """
  Computes the real provider cost for a single request.

  ## Arguments

    * `provider_reported_cost` — Decimal/number/string the upstream returned
      via `usage.cost` / top-level `cost` (when present), or `nil` when the
      upstream doesn't report a cost.
    * `manual_pricing` — optional map with `:input_cost_per_million`,
      `:output_cost_per_million`, `:cache_cost_per_million` and
      `:cache_write_cost_per_million` (Decimal or nil), expressed in the
      divisor of the lane's `pricing_unit`.
    * `usage` — optional map with `:prompt_tokens`, `:completion_tokens`,
      `:cache_read_tokens` and `:cache_creation_tokens` (integers).

  Returns a `Decimal.t()` — always a valid Decimal. An unparseable reported
  cost degrades to $0 (never trust unreviewed input).
  """
  @spec provider_cost(term(), keyword()) :: Decimal.t()
  def provider_cost(reported, opts \\ [])

  def provider_cost(nil, opts) do
    unit = Keyword.get(opts, :pricing_unit) || Pricing.default_unit()

    if Pricing.token_unit?(unit) do
      token_pricing(Keyword.get(opts, :manual_pricing), Keyword.get(opts, :usage, %{}), unit)
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

  # Token pricing: the `*_cost_per_million` columns are the PARAMETERS of the
  # token unit, so the rates are read verbatim and scaled by the unit's own
  # divisor (`per_1m_tokens` → 1M, `per_1k_tokens` → 1K). Dividing by a fixed
  # 1M made a per-1K lane bill 1000× less than its declared unit.
  defp token_pricing(
         %{input_cost_per_million: %Decimal{} = inp, output_cost_per_million: %Decimal{} = out} =
           pricing,
         usage,
         unit
       ) do
    rates = %{
      input: inp,
      output: out,
      cache_read: decimal_or_nil(Map.get(pricing, :cache_cost_per_million)),
      cache_write: decimal_or_nil(Map.get(pricing, :cache_write_cost_per_million))
    }

    token_cost(usage, rates, Decimal.new(Pricing.divisor(unit)))
  end

  defp token_pricing(_pricing, _usage, _unit), do: @zero

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

  # The manual token formula. `cache_read` nil → 2-term (all prompt at the
  # input rate); present → prompt is split so the cached subset bills at the
  # cache rate. `cache_write` adds a separate term over the creation tokens —
  # they are NOT part of `prompt_tokens` in the normalized contract, so there
  # is no subtraction (and no double charge): one count, one rate.
  defp token_cost(usage, rates, divisor) do
    prompt = tokens(usage, :prompt_tokens)
    cached = tokens(usage, :cache_read_tokens)
    creation = tokens(usage, :cache_creation_tokens)
    completion = tokens(usage, :completion_tokens)

    prompt_cost =
      case rates.cache_read do
        nil ->
          scaled(prompt, rates.input, divisor)

        cache_rate ->
          non_cached = Decimal.sub(prompt, cached) |> Decimal.max(@zero)

          Decimal.add(
            scaled(non_cached, rates.input, divisor),
            scaled(cached, cache_rate, divisor)
          )
      end

    write_cost =
      case rates.cache_write do
        nil -> @zero
        write_rate -> scaled(creation, write_rate, divisor)
      end

    prompt_cost
    |> Decimal.add(write_cost)
    |> Decimal.add(scaled(completion, rates.output, divisor))
    |> Decimal.round(6)
  end

  # tokens × rate / divisor, at full precision (rounding happens once, at the
  # end, so no term loses a fraction to an early round).
  defp scaled(count, rate, divisor) do
    count
    |> Decimal.div(divisor)
    |> Decimal.mult(rate)
  end

  defp tokens(usage, key) do
    Decimal.new("#{Map.get(usage, key, 0) || 0}")
  end

  defp decimal_or_nil(%Decimal{} = value), do: value
  defp decimal_or_nil(_), do: nil
end
