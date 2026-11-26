defmodule Tokengate.SmartRouter.CostRanker do
  @moduledoc """
  Layer 3's price tag: estimates what one request would cost on a destination
  lane and orders candidates by that estimate.

  The formula mirrors `Tokengate.Proxy.CostCalculator.token_pricing/3`, the
  only code that actually charges:

      cost = (prompt_tokens × input_rate
              + estimated_output_tokens × output_rate) / Pricing.divisor(unit)

  A non-token lane (`per_request`, `per_image`, …) is ranked by `unit_cost`;
  one request is one unit, which is enough to order lanes without pretending
  to know the billable quantity before the call.

  When the lane has no manual pricing, the model's informational
  `market_*_price_per_1m` is used as an estimate. When neither exists the
  candidate is **unpriced**: it sorts after every priced candidate instead of
  being ranked as `$0` (a missing price is not a free price).
  """

  alias Tokengate.Providers.Pricing

  @type analysis :: %{
          prompt_tokens: non_neg_integer(),
          estimated_output_tokens: non_neg_integer()
        }

  @doc """
  Estimates the request cost on `lane` (a lane map or a `ModelProvider`
  struct) with `model` for the market-price fallback.

  Returns a `Decimal` rounded to 6 places, or `nil` when no price is known.
  """
  @spec estimate(analysis(), map() | struct() | nil, map() | nil) :: Decimal.t() | nil
  def estimate(analysis, lane, model \\ nil) do
    unit = value(lane, :pricing_unit) || Pricing.default_unit()

    if Pricing.token_unit?(unit) do
      token_cost(analysis, lane, Pricing.divisor(unit)) ||
        market_cost(analysis, model)
    else
      unit_cost(lane) || market_cost(analysis, model)
    end
  end

  defp token_cost(analysis, lane, divisor) do
    input = decimal(value(lane, :input_cost_per_million))
    output = decimal(value(lane, :output_cost_per_million))

    if is_nil(input) or is_nil(output) do
      nil
    else
      prompt_terms = Decimal.mult(Decimal.new(analysis.prompt_tokens), input)
      output_terms = Decimal.mult(Decimal.new(analysis.estimated_output_tokens), output)

      prompt_terms
      |> Decimal.add(output_terms)
      |> Decimal.div(Decimal.new(divisor))
      |> Decimal.round(6)
    end
  end

  defp unit_cost(lane) do
    case decimal(value(lane, :unit_cost)) do
      nil ->
        nil

      cost ->
        unit = value(lane, :pricing_unit) || Pricing.default_unit()

        cost
        |> Decimal.div(Decimal.new(Pricing.divisor(unit)))
        |> Decimal.round(6)
    end
  end

  # Informational model prices are quoted per 1M tokens; they are the last
  # resort before "unpriced".
  defp market_cost(analysis, model) do
    input = decimal(value(model, :market_input_price_per_1m))
    output = decimal(value(model, :market_output_price_per_1m))

    if is_nil(input) and is_nil(output) do
      nil
    else
      prompt_terms = Decimal.mult(Decimal.new(analysis.prompt_tokens), input || Decimal.new(0))

      output_terms =
        Decimal.mult(Decimal.new(analysis.estimated_output_tokens), output || Decimal.new(0))

      prompt_terms
      |> Decimal.add(output_terms)
      |> Decimal.div(Decimal.new(1_000_000))
      |> Decimal.round(6)
    end
  end

  @doc """
  Ranks candidates cheapest-first.

  `mode`:

    * `:cost` — cheapest priced candidate first (the default; what a
      cost-oriented policy wants).
    * `:potency` — highest `effort_tier` first, then cheapest. Used when
      `critical_accuracy` inverts the tie-break or the policy is
      `quality_first`.

  Each candidate comes back with `:cost` (Decimal or nil) and `:lane` (the
  lane the estimate was computed on).
  """
  @spec rank([map()], analysis(), keyword()) :: [map()]
  def rank(candidates, analysis, opts \\ []) do
    mode = Keyword.get(opts, :mode, :cost)
    health_fun = Keyword.get(opts, :health_fun, fn _lane -> true end)

    candidates
    |> Enum.map(&annotate(&1, analysis, health_fun))
    |> Enum.sort_by(&sort_key(&1, mode))
  end

  defp annotate(candidate, analysis, health_fun) do
    lanes =
      candidate
      |> Map.get(:lanes, [])
      |> Enum.filter(fn lane -> health_fun.(lane) end)

    {lane, cost} = best_lane(lanes, analysis, candidate)

    candidate
    |> Map.put(:lane, lane)
    |> Map.put(:cost, cost)
    |> Map.put(:healthy, lane != nil)
  end

  # Cheapest priced lane; when every lane is unpriced, the first one by
  # priority is still a valid destination (it is just unpriced).
  defp best_lane([], _analysis, _model), do: {nil, nil}

  defp best_lane(lanes, analysis, model) do
    priced =
      lanes
      |> Enum.map(fn lane -> {lane, estimate(analysis, lane, model)} end)
      |> Enum.filter(fn {_lane, cost} -> cost != nil end)
      |> Enum.sort_by(fn {lane, cost} -> {Decimal.to_float(cost), priority(lane)} end)

    case priced do
      [{lane, cost} | _] ->
        {lane, cost}

      [] ->
        lane = Enum.min_by(lanes, &priority/1)
        {lane, nil}
    end
  end

  # A healthy destination always sorts before a degraded one; only then do the
  # mode's own criteria (price or potency) apply. Escalation must never land on
  # a circuit-open lane while a healthy one exists.
  defp sort_key(candidate, :potency) do
    {healthy_rank(candidate), -tier_rank(Map.get(candidate, :effort_tier)),
     cost_rank(Map.get(candidate, :cost)), Map.get(candidate, :priority, 100),
     Map.get(candidate, :model_name, "")}
  end

  defp sort_key(candidate, _mode) do
    {healthy_rank(candidate), cost_rank(Map.get(candidate, :cost)),
     Map.get(candidate, :priority, 100), tier_rank(Map.get(candidate, :effort_tier)),
     Map.get(candidate, :model_name, "")}
  end

  defp healthy_rank(candidate) do
    case Map.get(candidate, :healthy) do
      false -> 1
      _ -> 0
    end
  end

  # `{priced?, cost}`: unpriced is `{1, 0.0}`, so it never outranks a `$1.50`
  # destination (which is `{0, 1.5}`).
  defp cost_rank(nil), do: {1, 0.0}
  defp cost_rank(%Decimal{} = cost), do: {0, Decimal.to_float(cost)}
  defp cost_rank(cost) when is_number(cost), do: {0, cost * 1.0}
  defp cost_rank(_), do: {1, 0.0}

  defp priority(lane) do
    case value(lane, :priority) do
      value when is_integer(value) -> value
      _ -> 100
    end
  end

  @doc "Numeric weight of an effort tier (`any` sits between low and medium)."
  @spec tier_rank(String.t() | nil) :: integer()
  def tier_rank("high"), do: 3
  def tier_rank("medium"), do: 2
  def tier_rank("any"), do: 1
  def tier_rank("low"), do: 1
  def tier_rank(_), do: 0

  @doc "Tiers strictly more potent than `tier`, in escalation order."
  @spec tiers_above(String.t() | nil) :: [String.t()]
  def tiers_above("low"), do: ~w(medium high)
  def tiers_above("medium"), do: ~w(high)
  def tiers_above(nil), do: ~w(low medium high)
  def tiers_above(_), do: []

  @doc "Tiers strictly less potent than `tier`, in downgrade order."
  @spec tiers_below(String.t() | nil) :: [String.t()]
  def tiers_below("high"), do: ~w(medium low)
  def tiers_below("medium"), do: ~w(low)
  def tiers_below(nil), do: []
  def tiers_below(_), do: []

  # Lane and model maps come from the loader with atom keys, but a caller
  # (a test, a future policy) may hand string keys: both are accepted.
  defp value(%_{} = struct, key), do: Map.get(struct, key)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_, _), do: nil

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_number(value), do: Decimal.new(value)
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(_), do: nil
end
