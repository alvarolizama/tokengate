defmodule Tokengate.Proxy.CostCalculator do
  @moduledoc """
  Cost accounting across TokenGate's four cost dimensions.

  TokenGate never charges users — it tracks how much *value* is consumed,
  what it would cost at market price, and what is actually paid:

    * `estimated_cost_usd` — what the usage would cost at **market price**
      (model_alias `market_*_price_per_1m`). Computed pre-request with
      estimated tokens (budget check) and post-request with real tokens.
    * `cost_usd` — what this **specific provider charges** for the usage
      (model_provider `model_pricing`). Only meaningful for
      `pay_per_token` providers; `0` for `included` providers.
    * `provider_cost_usd` — what you **actually pay**. Prefers the cost
      reported by the provider in its response body (when available);
      otherwise uses the pricing-row calculation for `pay_per_token` or
      `0` for `included` (subscription / RPM-limited) providers.
    * `savings_usd` — `estimated_cost_usd - provider_cost_usd`: how much
      is saved versus buying at market price.

  All arithmetic uses `Decimal`; results are rounded to 6 decimal places
  (matching the `numeric(12,6)` columns in `request_logs`).
  """

  @per_million Decimal.new(1_000_000)
  @places 6

  @type usage :: %{
          optional(atom()) => non_neg_integer()
        }

  @doc """
  Market-price cost of a usage map for a model alias.

  Expects a map/struct with `:market_input_price_per_1m` and
  `:market_output_price_per_1m` Decimal fields. Cache-read tokens are
  priced as regular input at market (no market cache baseline).
  """
  @spec market_cost(map(), usage()) :: Decimal.t()
  def market_cost(model_alias, usage) do
    input = to_decimal(Map.get(model_alias, :market_input_price_per_1m))
    output = to_decimal(Map.get(model_alias, :market_output_price_per_1m))

    per_million(input, prompt_units(usage))
    |> Decimal.add(per_million(output, units(usage, :completion_tokens)))
    |> rounded()
  end

  @doc """
  Provider-specific cost of a usage map given a model pricing row.

  Cache tokens use their dedicated prices when set; otherwise they are
  billed at the regular input price. Returns nil when pricing is nil
  (e.g. subscription providers carry no pricing rows).
  """
  @spec provider_priced_cost(map() | nil, usage()) :: Decimal.t() | nil
  def provider_priced_cost(nil, _usage), do: nil

  def provider_priced_cost(pricing, usage) do
    input = to_decimal(Map.get(pricing, :input_price_per_1m))
    output = to_decimal(Map.get(pricing, :output_price_per_1m))
    cache_read = to_decimal(Map.get(pricing, :cache_read_price_per_1m)) || input
    cache_creation = to_decimal(Map.get(pricing, :cache_creation_price_per_1m)) || input

    regular_input = units(usage, :prompt_tokens)

    per_million(input, regular_input)
    |> Decimal.add(per_million(output, units(usage, :completion_tokens)))
    |> Decimal.add(per_million(cache_read, units(usage, :cache_read_tokens)))
    |> Decimal.add(per_million(cache_creation, units(usage, :cache_creation_tokens)))
    |> rounded()
  end

  @doc """
  What is actually paid for the request: the priced cost.
  """
  @spec real_provider_cost(Decimal.t() | nil) :: Decimal.t()
  def real_provider_cost(nil), do: Decimal.new(0)
  def real_provider_cost(%Decimal{} = priced_cost), do: priced_cost

  @doc """
  Savings versus market price: `estimated_cost_usd - provider_cost_usd`.
  """
  @spec savings(Decimal.t(), Decimal.t()) :: Decimal.t()
  def savings(%Decimal{} = estimated, %Decimal{} = provider_cost) do
    Decimal.sub(estimated, provider_cost) |> rounded()
  end

  @doc """
  Full four-dimension breakdown for one request.

    * `model_alias` — map/struct with market prices
    * `pricing` — model_pricing map/struct or nil
    * `usage` — normalized usage map
    * `opts` — keyword list with:
      * `:billing_mode` — `"pay_per_token"` (default) or `"included"`
      * `:provider_reported_cost` — decimal cost reported by the provider
        in its response body, when available. Takes precedence over the
        pricing-row calculation.

  Returns `%{estimated_cost_usd, cost_usd, provider_cost_usd, savings_usd}`
  with Decimal values.

  Billing mode semantics:
    * `pay_per_token` — `cost_usd` = pricing-row calculation (or estimated
      fallback when no pricing row exists); `provider_cost_usd` = the
      provider-reported cost when available, otherwise `cost_usd`.
    * `included` — `cost_usd` = `0` (no per-token charge);
      `provider_cost_usd` = `0`; budget enforcement uses `estimated_cost_usd`.
  """
  @spec breakdown(map(), map() | nil, usage(), keyword()) :: %{
          estimated_cost_usd: Decimal.t(),
          cost_usd: Decimal.t(),
          provider_cost_usd: Decimal.t(),
          savings_usd: Decimal.t()
        }
  def breakdown(model_alias, pricing, usage, opts \\ []) do
    billing_mode = Keyword.get(opts, :billing_mode, "pay_per_token")
    provider_reported = Keyword.get(opts, :provider_reported_cost)

    estimated = market_cost(model_alias, usage)

    {cost_usd, real} =
      case billing_mode do
        "included" ->
          {Decimal.new(0), Decimal.new(0)}

        _pay_per_token ->
          priced = provider_priced_cost(pricing, usage) || estimated

          real =
            case to_decimal(provider_reported) do
              nil -> real_provider_cost(provider_priced_cost(pricing, usage))
              reported -> reported
            end

          {priced, real}
      end

    %{
      estimated_cost_usd: estimated,
      cost_usd: cost_usd,
      provider_cost_usd: real,
      savings_usd: savings(estimated, real)
    }
  end

  # Cache-read tokens are part of the provider's prompt token count on some
  # APIs and separate on others; market_cost counts them as input either way.
  defp prompt_units(usage) do
    units(usage, :prompt_tokens) + units(usage, :cache_read_tokens) +
      units(usage, :cache_creation_tokens)
  end

  defp units(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp per_million(nil, _units), do: Decimal.new(0)

  defp per_million(%Decimal{} = price, units) do
    price |> Decimal.mult(Decimal.new(units)) |> Decimal.div(@per_million)
  end

  defp rounded(%Decimal{} = value), do: Decimal.round(value, @places)

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.new(to_string(n))
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
