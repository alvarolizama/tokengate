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

  Plus the four SmartRouter use-case passes, driven by the decision's
  `prompt_policy` (`keep_last_n_images/2`, `window_history/2`,
  `compact_json_tools/1`, `stale_tool_trim/2`). They only run on
  `model: "router"` requests and each one is a no-op when its knob is unset.

  Every function returns a brand-new list; the input is never mutated.
  """

  alias Tokengate.Proxy.TokenEstimator

  @max_content_length 40_000
  @truncation_marker "\n[... truncated]"

  # `stale_tool_trim/2`: the tail of the conversation that always survives and
  # the minimum size of a tool output worth replacing with a placeholder.
  @stale_tool_keep 2
  @stale_tool_tail 6
  @stale_tool_min_chars 400

  # What `keep_last_n_images/2` leaves where an old image used to be.
  @image_placeholder "[image omitted]"

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

  ## SmartRouter use-case passes ------------------------------------------
  #
  # These four passes are driven by the DECISION's `prompt_policy` (the
  # use-case row), so they only run on `model: "router"` requests. They are
  # pure and deterministic, and every one of them is a no-op when its knob is
  # unset — the default body stays byte-identical.

  # Image parts of a chat message, in any of the three dialects the gateway
  # forwards: OpenAI (`image_url`), Anthropic-style (`image`) and
  # Responses-style (`input_image`).
  @image_part_types ~w(image_url image input_image)

  @doc """
  Keeps images only in the last `n` image-bearing messages, replacing the
  earlier image parts with a short text placeholder.

  `computer_use` conversations accumulate screenshots turn after turn, and an
  old screenshot is worth thousands of input tokens while adding nothing to
  the current step. The placeholder keeps the message shape valid (a part list
  never becomes empty) and is deterministic, so prefix caching still works on
  the (untouched) head of the list.

  `nil` / non-positive `n` is a no-op.
  """
  @spec keep_last_n_images([map()], non_neg_integer() | nil) :: [map()]
  def keep_last_n_images(messages, n) when is_list(messages) and is_integer(n) and n >= 0 do
    indexed = Enum.with_index(messages)

    image_indexes =
      for {message, index} <- indexed, has_image?(message), do: index

    dropped =
      image_indexes
      |> Enum.drop(-n)
      |> MapSet.new()

    Enum.map(indexed, fn {message, index} ->
      if MapSet.member?(dropped, index), do: strip_images(message), else: message
    end)
  end

  def keep_last_n_images(messages, _n), do: messages

  @doc """
  Keeps the system block plus the last `turns` conversation turns.

  A "turn" starts at a `user` message; everything from the `turns`-th newest
  user message onwards is kept. Leading assistant/tool orphans left by the cut
  are dropped so the history never opens with a reply to a message that is no
  longer there (upstreams reject that shape).

  `nil` / non-positive `turns` is a no-op; the system block is never counted.
  """
  @spec window_history([map()], pos_integer() | nil) :: [map()]
  def window_history(messages, turns)
      when is_list(messages) and is_integer(turns) and turns > 0 do
    {system, rest} = Enum.split_with(messages, &(Map.get(&1, "role") == "system"))

    system ++
      (rest
       |> Enum.reverse()
       # `take_turns/4` walks backwards and prepends, so its accumulator is
       # already in conversation order.
       |> take_turns(turns, 0, [])
       |> drop_leading_non_user())
  end

  def window_history(messages, _turns), do: messages

  @doc """
  Compacts JSON that travels as a STRING inside the conversation — the fields
  the tokenizer pays for byte by byte:

    * `tool_calls[*].function.arguments` (a JSON-encoded string),
    * `tool` message content that is itself a JSON document,
    * `function_call.arguments` (the legacy field).

  Whitespace and `null`-valued keys are dropped deterministically; a value
  that does not parse as JSON, or that would not get smaller, is left exactly
  as it was. Order is preserved.
  """
  @spec compact_json_tools([map()]) :: [map()]
  def compact_json_tools(messages) when is_list(messages) do
    Enum.map(messages, &compact_message_json/1)
  end

  def compact_json_tools(messages), do: messages

  @doc """
  Estimated prompt tokens of a `messages` list, INCLUDING the JSON documents
  that travel as strings: `tool_calls[*].function.arguments` and the legacy
  `function_call.arguments`.

  `TokenEstimator.estimate_messages/1` only reads `content`, so a pass that
  shrinks nothing but those argument strings (`compact_json_tools/1`) used to
  measure a saving of exactly 0. The two halves use the same estimator, so the
  before/after difference is the saving those passes really produced.
  """
  @spec estimate_prompt_tokens([map()]) :: non_neg_integer()
  def estimate_prompt_tokens(messages) when is_list(messages) do
    TokenEstimator.estimate_messages(messages) +
      Enum.reduce(messages, 0, fn message, acc -> acc + argument_tokens(message) end)
  end

  def estimate_prompt_tokens(_), do: 0

  @doc """
  Trims the CONTENT of stale `tool` messages (old tool output) down to a short
  placeholder, gated on a saving threshold.

  "Stale" means: not one of the last #{@stale_tool_keep} tool messages and not
  inside the last #{@stale_tool_tail} messages of the conversation, and long
  enough to be worth trimming (#{@stale_tool_min_chars}+ chars). The most
  recent tool exchange always survives — it is what the model is answering.

  `opts`:

    * `:pinned` — the session is served by an active `SessionPin`, so its
      prompt prefix is (very likely) a hot upstream cache. Rewriting historical
      messages invalidates that prefix and costs MORE than the trim saves, so a
      pinned session only trims when the estimated saving reaches
      `threshold_pct` of the whole prompt. An unpinned conversation has no pin
      to protect: it trims whenever there is something stale to trim.

  `nil` (knob off) is a no-op either way.
  """
  @spec stale_tool_trim([map()], number() | nil, keyword()) :: [map()]
  def stale_tool_trim(messages, threshold_pct, opts \\ [])

  def stale_tool_trim(messages, threshold_pct, opts)
      when is_list(messages) and is_number(threshold_pct) and threshold_pct > 0 do
    indexed = Enum.with_index(messages)

    tool_indexes = for {message, index} <- indexed, Map.get(message, "role") == "tool", do: index
    keep = Enum.take(tool_indexes, -@stale_tool_keep) |> MapSet.new()
    tail_start = length(messages) - @stale_tool_tail

    candidates =
      tool_indexes
      |> Enum.reject(&MapSet.member?(keep, &1))
      |> Enum.reject(&(&1 >= tail_start))
      |> Enum.filter(fn index ->
        content = messages |> Enum.at(index) |> Map.get("content")
        is_binary(content) and byte_size(content) >= @stale_tool_min_chars
      end)
      |> MapSet.new()

    if MapSet.size(candidates) == 0 do
      messages
    else
      trimmed =
        Enum.map(indexed, fn {message, index} ->
          if MapSet.member?(candidates, index),
            do: Map.put(message, "content", stale_marker(Map.get(message, "content"))),
            else: message
        end)

      before = coarse_tokens(messages)
      after_tokens = coarse_tokens(trimmed)
      saved = max(before - after_tokens, 0)
      pinned? = Keyword.get(opts, :pinned, false)

      if pinned? and before > 0 and saved * 100 < threshold_pct * before,
        do: messages,
        else: trimmed
    end
  end

  def stale_tool_trim(messages, _threshold_pct, _opts), do: messages

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

  # ── SmartRouter pass helpers ──────────────────────────────────────────

  defp has_image?(message), do: has_image_part?(Map.get(message, "content"))

  defp has_image_part?(parts) when is_list(parts),
    do: Enum.any?(parts, &image_part?/1)

  defp has_image_part?(_), do: false

  defp image_part?(%{"type" => type}) when type in @image_part_types, do: true
  defp image_part?(_), do: false

  # Replaces every image part with a deterministic text placeholder. A part
  # list that would be left EMPTY keeps one placeholder part: an empty content
  # list is a 400 in most dialects.
  defp strip_images(message) do
    case Map.get(message, "content") do
      parts when is_list(parts) ->
        stripped =
          Enum.map(parts, fn part ->
            if image_part?(part),
              do: %{"type" => "text", "text" => @image_placeholder},
              else: part
          end)

        Map.put(message, "content", if(stripped == [], do: [text_part()], else: stripped))

      _ ->
        message
    end
  end

  defp text_part, do: %{"type" => "text", "text" => @image_placeholder}

  # Walks the conversation backwards, collecting messages until `remaining`
  # `user` messages have been counted; everything older is dropped.
  defp take_turns([], _remaining, _seen, acc), do: acc

  defp take_turns([message | rest], remaining, seen, acc) do
    if seen >= remaining do
      acc
    else
      role = Map.get(message, "role")
      seen = if role == "user", do: seen + 1, else: seen
      take_turns(rest, remaining, seen, [message | acc])
    end
  end

  # A windowed history must not open with a reply to a message that was cut.
  defp drop_leading_non_user(messages) do
    Enum.drop_while(messages, &(Map.get(&1, "role") != "user"))
  end

  defp compact_message_json(%{"role" => "tool", "content" => content} = message)
       when is_binary(content) do
    Map.put(message, "content", compact_json_string(content))
  end

  defp compact_message_json(%{"function_call" => %{"arguments" => args} = call} = message)
       when is_binary(args) do
    Map.put(message, "function_call", Map.put(call, "arguments", compact_json_string(args)))
  end

  defp compact_message_json(%{"tool_calls" => calls} = message) when is_list(calls) do
    Map.put(message, "tool_calls", Enum.map(calls, &compact_call_json/1))
  end

  defp compact_message_json(message), do: message

  defp compact_call_json(%{"function" => %{"arguments" => args} = function} = call)
       when is_binary(args) do
    Map.put(call, "function", Map.put(function, "arguments", compact_json_string(args)))
  end

  defp compact_call_json(call), do: call

  # Re-encodes a JSON document without whitespace or null-valued keys. Kept
  # ONLY when strictly smaller: a string that is not JSON (or that re-encodes
  # larger) is returned untouched, so the pass never grows a payload.
  defp compact_json_string(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        compacted = decoded |> drop_nulls() |> Jason.encode!()

        if byte_size(compacted) < byte_size(value), do: compacted, else: value

      _ ->
        value
    end
  end

  defp drop_nulls(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, drop_nulls(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp drop_nulls(list) when is_list(list), do: Enum.map(list, &drop_nulls/1)
  defp drop_nulls(value), do: value

  defp stale_marker(content),
    do: "[... omitted #{byte_size(content)} chars of tool output]"

  # Characters of the JSON that travels as a STRING inside a message. These are
  # the only fields `compact_json_tools/1` rewrites, and the tokenizer pays for
  # them byte by byte.
  defp argument_tokens(message) do
    message
    |> argument_strings()
    |> Enum.reduce(0, fn text, acc -> acc + TokenEstimator.estimate_text(text) end)
  end

  defp argument_strings(message) do
    tool_calls =
      case Map.get(message, "tool_calls") do
        calls when is_list(calls) -> Enum.flat_map(calls, &call_argument_strings/1)
        _ -> []
      end

    legacy =
      case Map.get(message, "function_call") do
        %{"arguments" => args} when is_binary(args) -> [args]
        _ -> []
      end

    tool_calls ++ legacy
  end

  defp call_argument_strings(%{"function" => %{"arguments" => args}}) when is_binary(args),
    do: [args]

  defp call_argument_strings(_), do: []

  # Coarse chars→tokens estimate used ONLY by the threshold gate: it compares
  # like with like (before vs after the same messages), so the exact ratio the
  # tokenizer applies does not change the decision.
  defp coarse_tokens(messages), do: messages |> Enum.map(&size_of/1) |> Enum.sum() |> div(4)

  defp size_of(value) when is_binary(value), do: byte_size(value)
  defp size_of(value) when is_list(value), do: value |> Enum.map(&size_of/1) |> Enum.sum()

  defp size_of(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> byte_size(to_string(key)) + size_of(nested) end)
    |> Enum.sum()
  end

  defp size_of(_value), do: 0

  # ── cleanup helpers ───────────────────────────────────────────────────

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
