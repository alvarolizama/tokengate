defmodule Tokengate.Proxy.CacheControlInjector do
  @moduledoc """
  Injects Anthropic-style `cache_control` breakpoints on the stable prompt
  prefix, gated by a per-model_provider flag.

  Why: implicit (automatic) prefix caching is best-effort — z.ai's cache is
  shared per upstream API key and evicts under concurrent traffic, and hit
  rates collapse when several conversations share one credential. Explicit
  `cache_control: {type: "ephemeral"}` breakpoints make the prefix hit
  deterministic on upstreams that honor them:

    * Anthropic (direct or via OpenRouter): guaranteed hits, reads −90%,
      writes +25% (5m TTL).
    * z.ai OpenAI-compatible endpoint: accepts Anthropic-style
      `cache_control` even though it is undocumented (verified by the
      community; see deepseek-harness #5227).
    * OpenRouter: passes `cache_control` through to Anthropic, and uses
      only the LAST breakpoint for Gemini.

  ## What it does

  The LAST system message's string content is split into content parts and
  the final part is marked `cache_control: %{type: "ephemeral"}`. This
  caches everything up to and including that breakpoint: the stable system
  block that `PromptOptimizer.stable_prefix/1` already hoisted to the front.

  Messages that already carry `cache_control` anywhere are left untouched
  (the client knows better). Non-string content (vision parts) is skipped —
  mutating those shapes is the client's domain.

  Only chat payloads with at least one system message are eligible. The
  inject pass runs AFTER `stable_prefix` + `lazy_cleanup` so the marked
  prefix is the final, canonical one.
  """

  @ephemeral %{"type" => "ephemeral"}

  @doc """
  Injects a `cache_control` breakpoint on the last system message of a chat
  payload. No-op (returns the payload unchanged) when:

    * `enabled` is false
    * there is no system message
    * the system content is not a plain string
    * any message already carries a `cache_control` marker
  """
  @spec inject(map(), boolean()) :: map()
  def inject(payload, enabled)

  def inject(payload, false), do: payload

  def inject(%{"messages" => messages} = payload, true) when is_list(messages) do
    if eligible?(messages) do
      Map.put(payload, "messages", inject_breakpoint(messages))
    else
      payload
    end
  end

  def inject(payload, true), do: payload

  ## Internals -------------------------------------------------------------

  # Eligible when at least one system message with string content exists
  # and no message already carries a cache_control marker.
  defp eligible?(messages) do
    has_string_system?(messages) and not already_marked?(messages)
  end

  defp has_string_system?(messages) do
    Enum.any?(messages, fn
      %{"role" => "system", "content" => content} -> is_binary(content)
      _ -> false
    end)
  end

  # A `cache_control` key on any content part of any message means the
  # client is managing breakpoints itself — don't fight it.
  defp already_marked?(messages) do
    Enum.any?(messages, fn
      %{"content" => parts} when is_list(parts) ->
        Enum.any?(parts, fn
          part when is_map(part) -> Map.has_key?(part, "cache_control")
          _ -> false
        end)

      %{"cache_control" => _} ->
        true

      _ ->
        false
    end)
  end

  # Walks to the LAST system message and marks its final content part.
  defp inject_breakpoint(messages) do
    last_system_idx =
      Enum.find_index(Enum.reverse(messages), fn
        %{"role" => "system", "content" => content} -> is_binary(content)
        _ -> false
      end)
      |> case do
        nil -> nil
        rev_idx -> length(messages) - 1 - rev_idx
      end

    case last_system_idx do
      nil ->
        messages

      idx ->
        List.update_at(messages, idx, fn %{"content" => content} = msg ->
          parts = [
            %{"type" => "text", "text" => content, "cache_control" => @ephemeral}
          ]

          Map.merge(msg, %{"content" => parts})
        end)
    end
  end
end
