defmodule Tokengate.Proxy.UsageNormalizer do
  @moduledoc """
  Normalizes provider usage payloads into TokenGate's internal usage shape:

      %{
        prompt_tokens: non_neg_integer,
        completion_tokens: non_neg_integer,
        cache_read_tokens: non_neg_integer,
        cache_creation_tokens: non_neg_integer
      }

  **Semantics**: `prompt_tokens` is the provider's raw total — for
  OpenAI-compatible APIs it INCLUDES cached tokens. `cache_read_tokens` is
  the cached subset of that total (from `prompt_tokens_details.cached_tokens`),
  kept for observability and so `CostCalculator` can price it at the cache
  rate: `(prompt − cached) × input + cached × cache + completion × output`.
  `cache_creation_tokens` is always 0 — no supported provider charges cache
  writes separately.

  Only `:openai` (OpenAI-compatible APIs) is supported. Streaming: the final
  chunk carries `usage` when the request sets
  `stream_options: {include_usage: true}` (the proxy forces it).

  Returns `nil` when the payload contains no usage data.
  """

  @type usage :: %{
          prompt_tokens: non_neg_integer,
          completion_tokens: non_neg_integer,
          cache_read_tokens: non_neg_integer,
          cache_creation_tokens: non_neg_integer
        }

  @doc """
  Normalizes a complete (non-streaming) provider response body.
  """
  @spec normalize(:openai, map()) :: usage() | nil
  def normalize(:openai, %{"usage" => usage}) when is_map(usage) do
    # prompt_tokens stays raw (includes cached tokens) — CostCalculator
    # subtracts the cached subset to price it at the cache rate.
    cached = get_in_int(usage, ["prompt_tokens_details", "cached_tokens"])

    %{
      prompt_tokens: get_int(usage, "prompt_tokens"),
      completion_tokens: get_int(usage, "completion_tokens"),
      cache_read_tokens: cached,
      cache_creation_tokens: 0
    }
  end

  def normalize(_provider, _body), do: nil

  @doc """
  Extracts the cost reported by the provider, if any.

  Checks, in order of preference:
    1. Body: `body["usage"]["cost"]` (OpenRouter) or `body["cost"]` (some providers)
    2. Headers: `x-litellm-response-cost` (LiteLLM proxy)

  Returns a `Decimal.t()` or `nil` when the provider doesn't report a cost.

  ## The `resp_headers` argument

  Pass the upstream's HTTP response headers (as a list of `{binary, binary}`
  tuples, lowercase keys). When `nil`, only the body is searched — matching
  the original behaviour before the LiteLLM header support was added.
  """
  @spec extract_reported_cost(:openai, map(), [{String.t(), String.t()}] | nil) ::
          Decimal.t() | nil
  def extract_reported_cost(provider, body, resp_headers \\ nil)

  def extract_reported_cost(:openai, body, resp_headers) do
    body_cost =
      get_in(body, ["usage", "cost"]) ||
        Map.get(body, "cost")

    to_decimal(body_cost) || extract_header_cost(resp_headers)
  end

  def extract_reported_cost(_provider, _body, _resp_headers), do: nil

  # Extracts cost from LiteLLM proxy response headers.
  # LiteLLM injects `x-litellm-response-cost` (USD as a float string, e.g.
  # "4.608e-05"). Returns nil when the header is absent or unparseable.
  @litellm_cost_header "x-litellm-response-cost"

  defp extract_header_cost(nil), do: nil

  defp extract_header_cost(headers) when is_list(headers) do
    case List.keyfind(headers, @litellm_cost_header, 0) do
      {@litellm_cost_header, value} -> to_decimal(value)
      _ -> nil
    end
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.new("#{n}")

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  @doc """
  Normalizes the usage payload of an OpenAI streaming final chunk.

  Same shape as the non-streaming response; returns nil when the chunk
  has no usage (all chunks except the last one).
  """
  @spec from_openai_stream_chunk(map()) :: usage() | nil
  def from_openai_stream_chunk(%{"usage" => usage}) when is_map(usage),
    do: normalize(:openai, %{"usage" => usage})

  def from_openai_stream_chunk(_chunk), do: nil

  defp get_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp get_in_int(map, [k1, k2]) do
    case Map.get(map, k1) do
      inner when is_map(inner) -> get_int(inner, k2)
      _ -> 0
    end
  end
end
