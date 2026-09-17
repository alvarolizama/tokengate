defmodule Tokengate.Proxy.PromptOptimizer do
  @moduledoc """
  Pre-flight transforms applied to the OpenAI-style `messages` payload right
  before it is forwarded to the upstream provider.

  Two pure, side-effect-free passes:

    * `stable_prefix/1` — hoists every `system` message to the front of the
      list, deduping by exact content, while leaving the order of all other
      messages untouched. Vision payloads (list-typed content) flow through
      unchanged and participate in ordering by their original position.

    * `lazy_cleanup/1` — collapses long, noisy, or repeated tool-output
      messages: deduplicates consecutive identical `tool` messages, trims
      string content longer than 40_000 chars, collapses runs of 3+ newlines
      to exactly two, and trims leading/trailing whitespace. Non-string
      content (lists, maps, nil) is left completely untouched.

    * `strip_reasoning/1` — removes `reasoning_content` (and the Anthropic
      `thinking` block) from historical `assistant` messages. Reasoning is
      an output artifact: re-sending it in the conversation history burns
      input tokens that the model recomputes anyway, and it breaks prefix
      stability when clients truncate it differently each turn. Assistant
      turns that carry `tool_calls` are the exception — see below.

  Both functions return a brand-new list; the input is never mutated.
  """

  @max_content_length 40_000
  @truncation_marker "\n[... truncated]"

  @doc """
  Hoists every `system` message to the front of the list, preserving relative
  order within the system block, and deduplicates identical system messages
  by exact content. Non-system messages keep their original relative order.
  """
  @spec stable_prefix([map()]) :: [map()]
  def stable_prefix(messages) when is_list(messages) do
    {systems, rest} = Enum.split_with(messages, &(Map.get(&1, "role") == "system"))

    deduped_systems =
      Enum.reduce(systems, [], fn msg, acc ->
        content = Map.get(msg, "content")

        cond do
          is_binary(content) ->
            normalized = String.trim(content)

            if Enum.any?(acc, fn existing ->
                 is_binary(Map.get(existing, "content")) and
                   String.trim(Map.get(existing, "content")) == normalized
               end) do
              acc
            else
              [msg | acc]
            end

          true ->
            [msg | acc]
        end
      end)
      |> Enum.reverse()

    deduped_systems ++ rest
  end

  def stable_prefix(_), do: []

  @doc """
  Cleanup pass over the messages list:

    * Consecutive `tool` messages with identical string content are deduped.
    * String content longer than #{@max_content_length} chars is trimmed to
      that length and suffixed with `#{inspect(@truncation_marker)}`.
    * Runs of 3+ newlines collapse to exactly two.
    * Leading/trailing whitespace in string content is removed.

  Non-string content (lists, maps, nil) is left untouched. Order is preserved.
  """
  @spec lazy_cleanup([map()]) :: [map()]
  def lazy_cleanup(messages) when is_list(messages) do
    {reversed, _} =
      Enum.reduce(messages, {[], :none}, &reduce_message/2)

    Enum.reverse(reversed)
  end

  def lazy_cleanup(_), do: []

  @doc """
  Removes reasoning artifacts from historical `assistant` messages:

    * drops the `reasoning_content` field (GLM / DeepSeek / Qwen dialects)
    * drops the `thinking` block (Anthropic-style messages)
    * drops the `reasoning` field (OpenAI Responses-style re-sends)

  Only `assistant` messages are touched; the final turn's reasoning (if the
  client intentionally included it) follows the same rule — reasoning is
  never a useful prefix. The LAST assistant message is treated identically:
  providers recompute reasoning server-side regardless.

  **Exception: assistant messages that carry `tool_calls` are passed through
  untouched.** A thinking-mode backend whose client is expected to continue
  the tool loop requires the reasoning of the tool-call turn back in the
  history, and rejects the whole request (400) when it is missing — the
  saving of one field is not worth a dead request:

      {"error": {"message": "The `reasoning_content` in the thinking mode
       must be passed back to the API."}}

  Anthropic's extended-thinking API states the same requirement for its
  `thinking` blocks around `tool_use`. Turns WITHOUT tool calls are still
  stripped: there the reasoning is pure output artifact.
  """
  @spec strip_reasoning([map()]) :: [map()]
  def strip_reasoning(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{"role" => "assistant"} = msg ->
        if tool_call_turn?(msg), do: msg, else: strip_reasoning_fields(msg)

      msg ->
        msg
    end)
  end

  def strip_reasoning(_), do: []

  # A turn that asked for tools: its reasoning is part of the turn's
  # contract with a thinking-mode upstream, not a disposable artifact.
  defp tool_call_turn?(message) do
    case Map.get(message, "tool_calls") do
      [_ | _] -> true
      _ -> false
    end
  end

  defp strip_reasoning_fields(message) do
    message
    |> Map.delete("reasoning_content")
    |> Map.delete("thinking")
    |> Map.delete("reasoning")
  end

  ## Internals -------------------------------------------------------------

  defp reduce_message(message, {acc, last_dedup_key}) do
    key = dedup_key(message)

    cond do
      match?({:tool, _}, key) and key == last_dedup_key ->
        {acc, last_dedup_key}

      true ->
        {[normalize_message(message) | acc], key}
    end
  end

  defp dedup_key(%{"role" => "tool", "content" => content}) when is_binary(content) do
    {:tool, content}
  end

  defp dedup_key(_), do: :keep

  defp normalize_message(%{"content" => content} = message) when is_binary(content) do
    message
    |> Map.put("content", normalize_string(content))
  end

  defp normalize_message(message), do: message

  defp normalize_string(content) do
    content
    |> truncate_if_long()
    |> collapse_blank_lines()
    |> String.trim()
  end

  defp truncate_if_long(content) when byte_size(content) > @max_content_length do
    # Slice by graphemes, not by bytes: binary_part/3 cuts at a raw byte
    # offset and can land mid multi-byte character (em-dash, emoji, accent),
    # leaving a dangling lead byte that makes the string invalid UTF-8. That
    # breaks Jason.encode!/2 downstream with "invalid byte 0x…" when the
    # payload is re-encoded for the provider.
    String.slice(content, 0, @max_content_length) <> @truncation_marker
  end

  defp truncate_if_long(content), do: content

  defp collapse_blank_lines(content) do
    Regex.replace(~r/\n{3,}/, content, "\n\n")
  end
end
