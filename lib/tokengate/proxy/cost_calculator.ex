defmodule Tokengate.Proxy.CostCalculator do
  @moduledoc """
  Cost accounting for TokenGate.

  Since the 2026-07-30 refactor, TokenGate tracks **one** cost dimension per
  request: `provider_cost_usd` — the amount the upstream reported it charged.

  Decision matrix (`billing_mode` × provider-reported availability):

      |                        | reported cost present | reported cost absent |
      | ---------------------- | --------------------- | --------------------- |
      | `pay_per_token`        | use the reported cost | $0 (honest fallback) |
      | `included` (sub/RPM)   | $0 (ignored)          | $0                    |

  When `provider_reported_cost` is `nil` and the upstream is `pay_per_token`,
  we record `$0` rather than estimating from a stale manual pricing row. The
  upstream is the source of truth; if it doesn't tell us what it charged, we
  don't make one up.

  All returned values are `Decimal.t()`. The proxy/controller path forwards
  the result to the `request_logs.provider_cost_usd` column (`numeric(12,6)`).
  """

  @zero Decimal.new(0)

  @doc """
  Computes the real provider cost for a single request.

  ## Arguments

    * `billing_mode` — `"pay_per_token"` or `"included"` from the
      `model_providers` row.
    * `provider_reported_cost` — Decimal/number/string the upstream returned
      via `usage.cost` / `usage.total_cost` / top-level `cost` (when present),
      or `nil` when the upstream doesn't report a cost.

  Returns a `Decimal.t()` — always a valid Decimal. `included` always returns
  $0, regardless of any reported cost. Unknown billing modes also return $0
  defensively (never trust unreviewed input).
  """
  @spec provider_cost(String.t() | atom() | term(), term()) :: Decimal.t()
  def provider_cost("included", _reported), do: @zero
  def provider_cost("pay_per_token", nil), do: @zero

  def provider_cost("pay_per_token", %Decimal{} = reported) do
    Decimal.round(reported, 6)
  end

  def provider_cost("pay_per_token", reported) when is_number(reported) do
    reported
    |> to_string()
    |> Decimal.new()
    |> Decimal.round(6)
  end

  def provider_cost("pay_per_token", reported) when is_binary(reported) do
    case Decimal.parse(reported) do
      {decimal, ""} -> Decimal.round(decimal, 6)
      _ -> @zero
    end
  end

  def provider_cost("pay_per_token", _reported), do: @zero

  # Unknown billing mode (or anything that isn't a recognized string) → $0.
  def provider_cost(_billing_mode, _reported), do: @zero
end
