defmodule Tokengate.SmartRouter.RuleEvaluator do
  @moduledoc """
  Layer 1's deterministic gate: operator rules (`router_rules`) evaluated
  against a `RequestAnalyzer` analysis. Zero HTTP, zero cost.

  ## Matching

  Every allow-listed condition present in `match_conditions` must hold (AND).
  A rule with no conditions matches every request. Conditions not in the
  allow-list are **not** ignored silently: they can only reach here through a
  direct database write (the changeset rejects them), and an unknown condition
  fails the match — a rule must never fire on a signal it does not understand.

  `content_regex` is matched against the last user message only, so a rule
  cannot fire on a keyword that appears in the system prompt. An invalid regex
  is treated as `nil` by the changeset and as a non-match here.

  ## Actions

  Rules run in `priority` order (lowest number first):

    * `force_use_case` — terminal. The first matching force wins and later
      rules are not evaluated: a pin must not be overridden by a broader rule.
    * `restrict_use_cases` — accumulated. Every matching restriction
      intersects the candidate set; a restriction that leaves nothing is
      dropped by the engine (never strand a request).
  """

  @type result :: %{
          force: String.t() | nil,
          restrict: [String.t()] | nil,
          matched: [String.t()],
          forced_by: String.t() | nil,
          restricted_by: [String.t()]
        }

  @doc """
  Evaluates `rules` (already limited to enabled rows, ordered by priority) for
  `analysis`.

  Returns `%{force, restrict, matched, forced_by, restricted_by}`; `matched`
  lists the rule names so the decision can carry them into the request log.
  """
  @spec evaluate([map()], map()) :: result()
  def evaluate(rules, analysis) do
    rules
    |> Enum.sort_by(&{priority(&1), name(&1)})
    |> Enum.reduce(
      %{force: nil, restrict: nil, matched: [], forced_by: nil, restricted_by: []},
      fn rule, acc -> apply_rule(rule, analysis, acc) end
    )
  end

  defp apply_rule(rule, analysis, acc) do
    cond do
      not enabled?(rule) -> acc
      acc.force != nil -> acc
      not matches?(rule, analysis) -> acc
      true -> fire(rule, acc)
    end
  end

  defp fire(rule, acc) do
    name = name(rule)
    keys = List.wrap(field(rule, :target_use_case_keys))
    acc = %{acc | matched: acc.matched ++ [name]}

    case field(rule, :action) do
      "force_use_case" ->
        case keys do
          [key | _] -> %{acc | force: key, forced_by: name}
          [] -> acc
        end

      "restrict_use_cases" ->
        %{
          acc
          | restrict: intersect(acc.restrict, keys),
            restricted_by: acc.restricted_by ++ [name]
        }

      _ ->
        acc
    end
  end

  defp intersect(nil, keys), do: keys
  defp intersect(current, keys), do: Enum.filter(current, &(&1 in keys))

  # ---------------------------------------------------------------------------
  # Conditions
  # ---------------------------------------------------------------------------

  defp matches?(rule, analysis) do
    conditions =
      case field(rule, :match_conditions) do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> %{}
      end

    Enum.all?(conditions, fn {key, expected} ->
      condition?(to_string(key), expected, analysis)
    end)
  end

  defp condition?("min_tokens", expected, analysis) when is_integer(expected),
    do: analysis.prompt_tokens >= expected

  defp condition?("max_tokens", expected, analysis) when is_integer(expected),
    do: analysis.prompt_tokens <= expected

  defp condition?("has_tools", expected, analysis) when is_boolean(expected),
    do: analysis.has_tools == expected

  defp condition?("has_vision", expected, analysis) when is_boolean(expected),
    do: analysis.has_vision == expected

  defp condition?("has_structured_output", expected, analysis) when is_boolean(expected),
    do: analysis.has_structured_output == expected

  defp condition?("reasoning_effort", expected, analysis),
    do: analysis.effort != nil and analysis.effort == expected

  defp condition?("agent_types", expected, analysis) when is_list(expected),
    do: analysis.agent_type != nil and analysis.agent_type in expected

  defp condition?("group_ids", expected, analysis) when is_list(expected),
    do: analysis.group_id != nil and analysis.group_id in expected

  defp condition?("service_ids", expected, analysis) when is_list(expected),
    do: analysis.service_id != nil and analysis.service_id in expected

  defp condition?("content_regex", expected, analysis) when is_binary(expected) do
    case Regex.compile(expected, "u") do
      {:ok, regex} when is_binary(analysis.last_user_message) ->
        Regex.match?(regex, analysis.last_user_message)

      _ ->
        false
    end
  end

  # Unknown condition or a value of the wrong shape: never a match.
  defp condition?(_key, _expected, _analysis), do: false

  # ---------------------------------------------------------------------------
  # Field access (structs from the loader, plain maps from tests)
  # ---------------------------------------------------------------------------

  defp field(%_{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp field(_, _), do: nil

  defp enabled?(rule) do
    case field(rule, :enabled) do
      false -> false
      _ -> true
    end
  end

  defp priority(rule) do
    case field(rule, :priority) do
      value when is_integer(value) -> value
      _ -> 100
    end
  end

  defp name(rule) do
    case field(rule, :name) do
      value when is_binary(value) -> value
      _ -> "unnamed"
    end
  end
end
