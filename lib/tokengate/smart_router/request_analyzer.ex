defmodule Tokengate.SmartRouter.RequestAnalyzer do
  @moduledoc """
  Layer 1's eyes: everything the router knows about a request **before** any
  model is picked, computed once and shared by every later layer.

  The analysis is pure (`payload` in, map out) so the deterministic layers and
  their tests never touch the database. It answers the questions the pre-filter
  and the rule evaluator need:

    * `prompt_tokens` — `TokenEstimator.estimate_messages/1` **plus** the
      serialized `tools` definitions and every `tool_calls` payload. The
      estimator alone ignores both, so a tool-heavy agent turn used to look
      small enough for a tiny-context model.
    * `estimated_output_tokens` — the client's `max_tokens` when present,
      otherwise `min(max(256, prompt_tokens / 2), 2048)`.
    * `has_tools`, `has_vision`, `has_structured_output` — the hard capability
      signals. Vision is found in image parts (`image_url` / `input_image`),
      tools in the `tools` array or in tool messages, structured output in
      `response_format` (or the Responses-style `text.format`).
    * `effort` — from `Proxy.Reasoning.parse/1`, normalized to
      `low | medium | high | nil`; `think: true` with no named effort means
      `"high"`.
    * `tool_loop` — **open** tool loop: the conversation ends with a tool
      result, so the next turn must go to the model that opened the loop.
  """

  alias Tokengate.Proxy.{Reasoning, TokenEstimator}

  @type t :: %{
          prompt_tokens: non_neg_integer(),
          estimated_output_tokens: non_neg_integer(),
          has_tools: boolean(),
          has_vision: boolean(),
          has_structured_output: boolean(),
          tool_loop: boolean(),
          effort: String.t() | nil,
          think: boolean(),
          last_user_message: String.t() | nil,
          message_count: non_neg_integer(),
          agent_type: String.t() | nil,
          group_id: String.t() | nil,
          service_id: String.t() | nil,
          user_id: String.t() | nil
        }

  @default_output_tokens 256
  @max_heuristic_output_tokens 2048

  @doc """
  Analyzes a chat-completions payload (`context` may carry `agent_type`,
  `group_id` and `service_id` for rule matching).
  """
  @spec analyze(map() | nil, map()) :: t()
  def analyze(payload, context \\ %{}) do
    payload = if is_map(payload), do: payload, else: %{}
    messages = if is_list(payload["messages"]), do: payload["messages"], else: []

    prompt_tokens =
      TokenEstimator.estimate_messages(messages) +
        tools_tokens(payload["tools"]) +
        tool_calls_tokens(messages)

    {think, effort} = Reasoning.parse(payload)
    effort = normalize_effort(effort, think)

    %{
      prompt_tokens: prompt_tokens,
      estimated_output_tokens: output_tokens(payload, prompt_tokens),
      has_tools: has_tools?(payload, messages),
      has_vision: has_vision?(payload, messages),
      has_structured_output: structured_output?(payload),
      tool_loop: tool_loop?(messages),
      effort: effort,
      think: think or effort == "high",
      last_user_message: last_user_message(messages),
      message_count: length(messages),
      agent_type: context_value(context, :agent_type),
      # The USER behind the member (nil for a service member): the same
      # identity the proxy resolves as the spend subject, so a `user_ids` rule
      # matches the caller the operator named.
      user_id: context_value(context, :user_id),
      group_id: context_value(context, :group_id),
      service_id: context_value(context, :service_id)
    }
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  defp tools_tokens(tools) when is_list(tools) and tools != [] do
    TokenEstimator.estimate_text(Jason.encode!(tools))
  end

  defp tools_tokens(_), do: 0

  # `tool_calls` carries the model's arguments, which the prompt estimator never
  # sees: counting them keeps a tool-heavy history from passing the context-window
  # filter of a small model.
  defp tool_calls_tokens(messages) do
    messages
    |> Enum.reduce(0, fn message, acc ->
      acc +
        case message do
          %{"tool_calls" => calls} when is_list(calls) and calls != [] ->
            TokenEstimator.estimate_text(Jason.encode!(calls))

          _ ->
            0
        end
    end)
  end

  defp output_tokens(payload, prompt_tokens) do
    case positive_integer(
           payload["max_tokens"] || payload["max_completion_tokens"] ||
             payload["max_output_tokens"]
         ) do
      nil ->
        prompt_tokens
        |> div(2)
        |> max(@default_output_tokens)
        |> min(@max_heuristic_output_tokens)

      max_tokens ->
        max_tokens
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  # ---------------------------------------------------------------------------
  # Capability signals
  # ---------------------------------------------------------------------------

  defp has_tools?(payload, messages) do
    tool_list?(payload["tools"]) or
      Enum.any?(messages, fn
        %{"role" => "tool"} -> true
        %{"tool_calls" => [_ | _]} -> true
        _ -> false
      end)
  end

  defp tool_list?(tools), do: is_list(tools) and tools != []

  defp has_vision?(payload, messages) do
    image_part?(payload) or Enum.any?(messages, &image_part?/1)
  end

  # Scans content parts (and the Responses API's `input` / `output` lists) for
  # the two image part names the gateway's dialects use.
  defp image_part?(%{} = map) do
    Map.get(map, "type") in ["image_url", "input_image"] or
      Enum.any?(Map.values(map), &image_part?/1)
  end

  defp image_part?(list) when is_list(list), do: Enum.any?(list, &image_part?/1)
  defp image_part?(_), do: false

  defp structured_output?(payload) do
    case payload["response_format"] do
      %{"type" => "text"} -> false
      %{} -> true
      format when is_binary(format) -> format != "text"
      _ -> nested_format?(payload)
    end or payload["json_schema"] != nil
  end

  defp nested_format?(payload) do
    case payload["text"] do
      %{"format" => %{} = format} -> Map.get(format, "type") != "text"
      _ -> false
    end
  end

  # An OPEN tool loop ends with a tool result; it is the one shape that must not
  # be re-decided mid-task. A plain assistant `tool_calls` in the middle of a
  # history is not open (the following tool result closes it).
  defp tool_loop?(messages) do
    case List.last(messages) do
      %{"role" => "tool"} -> true
      %{"tool_call_id" => _} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Reasoning effort
  # ---------------------------------------------------------------------------

  @efforts ~w(low medium high)

  defp normalize_effort(effort, think) do
    cond do
      is_binary(effort) and effort in @efforts -> effort
      think -> "high"
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Content
  # ---------------------------------------------------------------------------

  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%{"role" => "user"}, &1))
    |> content_text()
  end

  defp content_text(%{"content" => content}), do: content_text(content)

  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp content_text(_), do: nil

  defp context_value(context, key) do
    case Map.get(context, key) || Map.get(context, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
