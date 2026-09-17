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
  `cache_creation_tokens` mirrors `prompt_tokens_details.cache_write_tokens`
  when the provider reports it (OpenRouter, explicit-caching upstreams);
  0 otherwise.

  Only `:openai` (OpenAI-compatible APIs) is supported. Streaming: the final
  chunk carries `usage` when the request sets
  `stream_options: {include_usage: true}` (the proxy forces it).

  Returns `nil` when the payload contains no usage data.
  """

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer()
        }

  # Fireworks Serverless response header carrying the cached portion of the
  # input tokens. Caching is on by default for every Serverless model, so the
  # discount applies on every cache hit; without reading this header the
  # saving is invisible in the logs (it looks like full-price input).
  @fireworks_cached_tokens_header "fireworks-cached-prompt-tokens"

  @doc """
  Normalizes a complete (non-streaming) provider response body.

  `resp_headers` (optional) carries the upstream response headers, used to
  recover the cached-prompt-token count on upstreams that report it there
  instead of in the body — Fireworks sets `fireworks-prompt-tokens` and
  `fireworks-cached-prompt-tokens` on every Serverless response, and
  streaming responses carry no `usage` in the chunked body.
  """
  @spec normalize(:openai, map(), [{String.t(), String.t()}] | nil) :: usage() | nil
  def normalize(:openai, %{"usage" => usage}, resp_headers) when is_map(usage) do
    # prompt_tokens stays raw (includes cached tokens) — CostCalculator
    # subtracts the cached subset to price it at the cache rate.
    cached = get_in_int(usage, ["prompt_tokens_details", "cached_tokens"])
    # OpenRouter (and some explicit-caching providers) report cache WRITES
    # separately — `cache_write_tokens`. Anthropic-style upstreams bill
    # writes at a premium (25–100%), so persisting them keeps cost
    # accounting honest even though the calculator doesn't price them yet.
    cache_write = get_in_int(usage, ["prompt_tokens_details", "cache_write_tokens"])

    %{
      prompt_tokens: get_int(usage, "prompt_tokens"),
      completion_tokens: get_int(usage, "completion_tokens"),
      # A body-reported cached count wins; headers are the fallback for
      # upstreams that only expose it there (or for streaming).
      cache_read_tokens: max(cached, cached_from_headers(resp_headers)),
      cache_creation_tokens: cache_write
    }
  end

  # Non-OpenAI dialects, and OpenAI-compatible bodies without a `usage`
  # object, yield no usage (the original behaviour).
  def normalize(_provider, _body, _resp_headers), do: nil

  @doc """
  Arity-2 convenience: normalizes without upstream headers.
  """
  @spec normalize(:openai, map()) :: usage() | nil
  def normalize(provider, body), do: normalize(provider, body, nil)

  # Fireworks Serverless reports the cached-prompt-token split in headers:
  #   fireworks-prompt-tokens         — total input tokens
  #   fireworks-cached-prompt-tokens  — the cached portion (billed at a
  #                                     discount, default 50% of input)
  # Reads the cached count only; the total is redundant with the body's
  # `prompt_tokens` and the body is authoritative for the other counters.
  defp cached_from_headers(nil), do: 0

  defp cached_from_headers(headers) when is_list(headers) do
    case List.keyfind(headers, @fireworks_cached_tokens_header, 0) do
      {@fireworks_cached_tokens_header, value} -> parse_int(value)
      _ -> 0
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_int(_), do: 0

  @doc """
  Extracts the cost reported by the provider, if any.

  Checks, in order of preference:
    1. Body: `body["usage"]["cost"]` (OpenRouter) or `body["cost"]` (some providers)
    2. Body: `body["usage"]["buyer_cost_micro"]` (Surplus Intelligence) — an
       integer in micro-USD, converted to USD
    3. Headers: `x-litellm-response-cost` (LiteLLM proxy)
    4. Headers: `x-si-buyer-cost-micro` (Surplus Intelligence) — same micro-USD
       unit as the body field

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

    to_decimal(body_cost) || micro_body_cost(body) || extract_header_cost(resp_headers)
  end

  def extract_reported_cost(_provider, _body, _resp_headers), do: nil

  # Surplus Intelligence (marketplace) reports what it charged the buyer in
  # micro-USD — the same unit its on-chain settlement uses (1 micro = $0.000001).
  # The field rides `usage` in the body, so it survives streaming too (the
  # final chunk carries the same `usage`); the header is the fallback for
  # responses with no JSON body.
  @si_cost_header "x-si-buyer-cost-micro"
  @micro_cost_key "buyer_cost_micro"
  @micro_usd Decimal.new(1_000_000)

  # Extracts cost from LiteLLM proxy response headers.
  # LiteLLM injects `x-litellm-response-cost` (USD as a float string, e.g.
  # "4.608e-05"). Returns nil when the header is absent or unparseable.
  @litellm_cost_header "x-litellm-response-cost"

  defp extract_header_cost(nil), do: nil

  defp extract_header_cost(headers) when is_list(headers) do
    case List.keyfind(headers, @litellm_cost_header, 0) do
      {@litellm_cost_header, value} ->
        to_decimal(value)

      _ ->
        case List.keyfind(headers, @si_cost_header, 0) do
          {@si_cost_header, value} -> micro_to_usd(value)
          _ -> nil
        end
    end
  end

  defp micro_body_cost(body) when is_map(body) do
    body |> get_in(["usage", @micro_cost_key]) |> micro_to_usd()
  end

  defp micro_body_cost(_body), do: nil

  defp micro_to_usd(value) when is_integer(value) and value >= 0 do
    Decimal.div(Decimal.new(value), @micro_usd)
  end

  defp micro_to_usd(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {micro, ""} when micro >= 0 -> micro_to_usd(micro)
      _ -> nil
    end
  end

  # Floats would silently truncate a sub-micro remainder; only exact integers
  # are accepted (a partial micro-USD is not a thing the marketplace reports).
  defp micro_to_usd(_value), do: nil

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

  `resp_headers` (optional) is the upstream's response headers — streaming
  responses on some upstreams (Fireworks Serverless) carry the
  cached-prompt-token split ONLY in headers, so the body's `usage` alone
  undercounts cache reads.
  """
  @spec from_openai_stream_chunk(map(), [{String.t(), String.t()}] | nil) :: usage() | nil
  def from_openai_stream_chunk(chunk, resp_headers \\ nil)

  def from_openai_stream_chunk(%{"usage" => usage}, resp_headers) when is_map(usage) do
    normalize(:openai, %{"usage" => usage}, resp_headers)
  end

  def from_openai_stream_chunk(_chunk, _resp_headers), do: nil

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
