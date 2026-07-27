defmodule Tokengate.Proxy.UsageNormalizer do
  @moduledoc """
  Normalizes provider-specific usage payloads into TokenGate's internal
  usage shape:

      %{
        prompt_tokens: non_neg_integer,
        completion_tokens: non_neg_integer,
        cache_read_tokens: non_neg_integer,
        cache_creation_tokens: non_neg_integer
      }

  **Semantics**: `prompt_tokens` is the count of *regular* (non-cached)
  input tokens — cache tokens are always reported separately. OpenAI's
  `usage.prompt_tokens` includes cached tokens, so they are subtracted;
  Anthropic's `input_tokens` already excludes cache tokens. This keeps
  cost arithmetic uniform across providers (input × prompt + cache ×
  cache price, never double-counted).

  Supported providers:

    * `:openai` — `usage.prompt_tokens` / `completion_tokens`,
      cached tokens from `prompt_tokens_details.cached_tokens`.
      Streaming: final chunk carries `usage` when the request set
      `stream_options: {include_usage: true}`.
    * `:anthropic` — `usage.input_tokens` / `output_tokens`,
      `cache_read_input_tokens`, `cache_creation_input_tokens`.
      Streaming: `message_start` carries input tokens, each
      `message_delta` carries cumulative output tokens.

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
  @spec normalize(:openai | :anthropic, map()) :: usage() | nil
  def normalize(:openai, %{"usage" => usage}) when is_map(usage) do
    cached = get_in_int(usage, ["prompt_tokens_details", "cached_tokens"])
    # OpenAI's prompt_tokens INCLUDES cached tokens — subtract them so
    # prompt_tokens is regular (non-cached) input, matching Anthropic.
    regular_input = max(get_int(usage, "prompt_tokens") - cached, 0)

    %{
      prompt_tokens: regular_input,
      completion_tokens: get_int(usage, "completion_tokens"),
      cache_read_tokens: cached,
      cache_creation_tokens: 0
    }
  end

  def normalize(:anthropic, %{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: get_int(usage, "input_tokens"),
      completion_tokens: get_int(usage, "output_tokens"),
      cache_read_tokens: get_int(usage, "cache_read_input_tokens"),
      cache_creation_tokens: get_int(usage, "cache_creation_input_tokens")
    }
  end

  def normalize(_provider, _body), do: nil

  @doc """
  Extracts the cost reported by the provider in its response body, if any.

  OpenRouter includes `body["usage"]["cost"]` as a float (USD).
  Other OpenAI-compatible providers may include it under `body["cost"]`.

  Returns a `Decimal.t()` or `nil` when the provider doesn't report a cost.
  """
  @spec extract_reported_cost(:openai | :anthropic, map()) :: Decimal.t() | nil
  def extract_reported_cost(:openai, body) do
    cost =
      get_in(body, ["usage", "cost"]) ||
        Map.get(body, "cost")

    to_decimal(cost)
  end

  def extract_reported_cost(:anthropic, body) do
    cost = get_in(body, ["usage", "cost"]) || Map.get(body, "cost")
    to_decimal(cost)
  end

  def extract_reported_cost(_provider, _body), do: nil

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

  @doc """
  Creates an accumulator for Anthropic streaming events.

  Feed each SSE event map through `apply_anthropic_event/2` and call
  `finalize_anthropic/1` when the stream ends.
  """
  @spec anthropic_accumulator() :: map()
  def anthropic_accumulator do
    %{prompt_tokens: 0, completion_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0}
  end

  @doc """
  Applies one Anthropic SSE event to the accumulator.

    * `message_start` — sets input tokens (and cache tokens) from `message.usage`
    * `message_delta` — updates output tokens from `usage.output_tokens`
      (cumulative, so it overwrites rather than adds)
  """
  @spec apply_anthropic_event(map(), map()) :: map()
  def apply_anthropic_event(acc, %{"type" => "message_start", "message" => %{"usage" => usage}}) do
    %{
      acc
      | prompt_tokens: get_int(usage, "input_tokens"),
        cache_read_tokens: get_int(usage, "cache_read_input_tokens"),
        cache_creation_tokens: get_int(usage, "cache_creation_input_tokens")
    }
  end

  def apply_anthropic_event(acc, %{"type" => "message_delta", "usage" => usage}) do
    %{acc | completion_tokens: get_int(usage, "output_tokens")}
  end

  def apply_anthropic_event(acc, _event), do: acc

  @doc """
  Finalizes an Anthropic stream accumulator into a usage map.
  """
  @spec finalize_anthropic(map()) :: usage()
  def finalize_anthropic(acc) when is_map(acc) do
    %{
      prompt_tokens: acc.prompt_tokens,
      completion_tokens: acc.completion_tokens,
      cache_read_tokens: acc.cache_read_tokens,
      cache_creation_tokens: acc.cache_creation_tokens
    }
  end

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
