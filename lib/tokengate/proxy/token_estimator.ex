defmodule Tokengate.Proxy.TokenEstimator do
  @moduledoc """
  Heuristic token estimation for pre-request budget and rate-limit checks.

  TokenGate uses a two-phase token counting strategy:

    * **Pre-request** — this module estimates tokens with `ceil(chars / 4)`
      so budgets and RPM/TPM limits can be enforced before calling the provider.
    * **Post-request** — the provider's real `usage` payload (normalized by
      `Tokengate.Proxy.UsageNormalizer`) is used for cost accounting.

  The heuristic intentionally over-estimates slightly; real usage is stored
  alongside estimates so accuracy can be compared over time.
  """

  @chars_per_token 4
  @per_message_overhead 4
  @image_part_tokens 85

  @doc """
  Estimates the number of tokens in a plain text string.
  """
  @spec estimate_text(String.t()) :: non_neg_integer
  def estimate_text(text) when is_binary(text) do
    ceil(String.length(text) / @chars_per_token)
  end

  @doc """
  Estimates tokens for an OpenAI-style `messages` list.

  Handles both string content and multi-part content (text + image_url parts).
  Adds a small per-message overhead matching OpenAI's published heuristic.
  """
  @spec estimate_messages([map()]) :: non_neg_integer
  def estimate_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      acc + @per_message_overhead + estimate_content(Map.get(message, "content"))
    end)
  end

  @doc """
  Estimates tokens for an accumulated completion string (streaming fallback).

  Used when a provider does not return usage data: the accumulated completion
  text is estimated with the same chars/4 heuristic.
  """
  @spec estimate_completion(String.t()) :: non_neg_integer
  def estimate_completion(text) when is_binary(text), do: estimate_text(text)

  defp estimate_content(nil), do: 0
  defp estimate_content(content) when is_binary(content), do: estimate_text(content)

  defp estimate_content(parts) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      %{"type" => "text", "text" => text}, acc when is_binary(text) ->
        acc + estimate_text(text)

      %{"type" => "image_url"}, acc ->
        acc + @image_part_tokens

      _other, acc ->
        acc
    end)
  end
end
