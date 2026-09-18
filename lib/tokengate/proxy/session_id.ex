defmodule Tokengate.Proxy.SessionId do
  @moduledoc """
  Derives a stable per-conversation session key for cache affinity.

  Prompt caches upstream are keyed by conversation, but TokenGate's API keys
  are not: one key typically carries many parallel conversations, and they
  evict each other's cached prefixes when they share a single affinity
  domain. This module derives a key that separates them. The key drives
  sticky routing and the session HEADERs only — it is never attached to
  the upstream body.

  Resolution order (first match wins):

    1. Client-provided `session_id` in the request body (max 256 chars —
       OpenRouter's documented limit).
    2. Client-provided `x-session-id` header (via the caller).
    3. Client-provided `prompt_cache_key` body field (OpenAI convention —
       read here for affinity only; the gateway never sends it upstream).
    4. Derived: SHA-256 of the first `system` message content plus the
       first non-system message content — the same heuristic OpenRouter
       uses to fingerprint a conversation's opening.

  Returns `nil` when nothing can be derived (no messages, empty payload) —
  callers then fall back to the API-key hash, preserving today's behaviour.

  All functions are pure; no side effects, no state.
  """

  @max_session_id_len 256

  @doc """
  Derives the session key from a chat payload (string keys) and the
  optional `x-session-id` header value.
  """
  @spec derive(map() | nil, String.t() | nil) :: String.t() | nil
  def derive(payload, session_header \\ nil)

  def derive(nil, session_header) do
    normalize(session_header)
  end

  def derive(payload, session_header) when is_map(payload) do
    normalize(payload["session_id"]) ||
      normalize(session_header) ||
      normalize(payload["prompt_cache_key"]) ||
      derive_from_messages(payload["messages"])
  end

  def derive(_, session_header), do: normalize(session_header)

  # Hashes a conversation's opening (first system + first non-system
  # message), mirroring OpenRouter's fingerprint heuristic. Only string
  # content participates; structured content lists are skipped so vision
  # payloads can't crash the derivation.
  defp derive_from_messages(messages) when is_list(messages) do
    with system_content when is_binary(system_content) <- first_content(messages, "system"),
         opener_content when is_binary(opener_content) <-
           first_non_system_content(messages) do
      :crypto.hash(:sha256, system_content <> "\u0000" <> opener_content)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)
    else
      _ -> nil
    end
  end

  defp derive_from_messages(_), do: nil

  defp first_content(messages, role) do
    case Enum.find(messages, fn msg -> is_map(msg) and msg["role"] == role end) do
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp first_non_system_content(messages) do
    case Enum.find(messages, fn msg ->
           is_map(msg) and msg["role"] in [nil, "user", "assistant", "tool"]
         end) do
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp normalize(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      String.slice(trimmed, 0, @max_session_id_len)
    end
  end

  defp normalize(_), do: nil
end
