defmodule Tokengate.Proxy.Reasoning do
  @moduledoc """
  Parses reasoning/thinking flags from a chat completion payload.

  Every provider names them differently:

    * OpenAI classic — `reasoning_effort: "low" | "medium" | "high"`
      (`"none"`/`"minimal"` mean thinking OFF but are kept as the effort)
    * OpenAI new — `reasoning: %{"effort" => ...}` or `%{"enabled" => bool}`
    * Anthropic / GLM — `thinking: %{"type" => "enabled"}` or plain boolean

  Returns `{think :: boolean(), effort :: String.t() | nil}`.
  """

  @doc """
  Extracts `{think, effort}` from a request payload map (string keys).
  """
  @spec parse(map()) :: {boolean(), String.t() | nil}
  def parse(payload) when is_map(payload) do
    effort = effort_from(payload)
    think = think_from(payload, effort)

    {think, effort}
  end

  ## Internals -------------------------------------------------------------

  defp effort_from(payload) do
    payload["reasoning_effort"] || nested(payload, ["reasoning", "effort"])
  end

  defp think_from(payload, effort) do
    cond do
      is_binary(effort) and effort not in ["none", "minimal"] ->
        true

      thinking_flag?(payload["thinking"]) ->
        true

      reasoning_enabled?(payload["reasoning"]) ->
        true

      true ->
        false
    end
  end

  defp thinking_flag?(%{"type" => type}) when is_binary(type), do: type == "enabled"
  defp thinking_flag?(flag) when is_boolean(flag), do: flag
  defp thinking_flag?(_), do: false

  defp reasoning_enabled?(%{"enabled" => enabled}) when is_boolean(enabled), do: enabled
  defp reasoning_enabled?(_), do: false

  defp nested(map, [key]) when is_map(map), do: Map.get(map, key)
  defp nested(map, [key | rest]) when is_map(map), do: nested(Map.get(map, key), rest)
  defp nested(_, _), do: nil
end
