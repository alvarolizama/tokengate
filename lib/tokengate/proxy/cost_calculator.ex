defmodule Tokengate.Proxy.CostCalculator do
  @moduledoc """
  Cost accounting for TokenGate.

  TokenGate tracks **one** cost dimension per request: `provider_cost_usd` —
  the amount the upstream charged for the request.

  ## Decision chain (first wins)

      1. Upstream-reported cost — `usage.cost` in the body or
         `x-litellm-response-cost` header. The upstream is the source of truth.
      2. Manual pricing fallback — `input_cost_per_million` and
         `output_cost_per_million` on the model_provider row, multiplied by
         the actual token counts from the response usage. Only applies when
         the upstream is silent AND both fields are set.
      3. $0 — honest fallback. We don't invent costs.

  `included` (subscription/RPM) always returns $0 regardless of any reported
  or manual cost.

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
    * `manual_pricing` — optional map with `:input_cost_per_million` and
      `:output_cost_per_million` (Decimal or nil). When the reported cost is
      absent and both are non-nil, the cost is computed from token counts.
    * `usage` — optional map with `:prompt_tokens` and `:completion_tokens`
      (integers). Required when `manual_pricing` is used.

  Returns a `Decimal.t()` — always a valid Decimal. `included` always returns
  $0, regardless of any reported cost. Unknown billing modes also return $0
  defensively (never trust unreviewed input).
  """
  @spec provider_cost(String.t() | atom() | term(), term(), keyword()) :: Decimal.t()
  def provider_cost(billing_mode, reported, opts \\ [])

  def provider_cost("included", _reported, _opts), do: @zero

  def provider_cost("pay_per_token", nil, opts) do
    case Keyword.get(opts, :manual_pricing) do
      %{input_cost_per_million: %Decimal{} = inp, output_cost_per_million: %Decimal{} = out}
      when inp != nil and out != nil ->
        usage = Keyword.get(opts, :usage, %{})
        manual_cost(usage, inp, out)

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

  # Computes cost from manual pricing: (prompt_tokens / 1M * input_rate) +
  # (completion_tokens / 1M * output_rate). Rounds to 6 decimal places.
  defp manual_cost(usage, input_rate, output_rate) do
    prompt = Decimal.new("#{Map.get(usage, :prompt_tokens, 0)}")
    completion = Decimal.new("#{Map.get(usage, :completion_tokens, 0)}")

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
end
