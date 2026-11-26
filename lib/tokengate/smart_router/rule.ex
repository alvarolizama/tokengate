defmodule Tokengate.SmartRouter.Rule do
  @moduledoc """
  An operator rule (`router_rules`) evaluated above the classifier.

  Rules are the deterministic layer: they cost 0 ms and $0 and run **before**
  the LLM is asked anything, so a rule can protect a critical specialty from
  being downgraded, or force a specialty for a known shape of request without
  paying for a decision.

  ## Conditions

  `match_conditions` is jsonb validated here before it reaches the database.
  Every key is optional and only the allow-listed signals are accepted, so an
  operator typo fails at the form instead of being silently ignored at runtime:

  | Key                        | Type              |
  |----------------------------|-------------------|
  | `min_tokens` / `max_tokens`| integer (>= 0)    |
  | `has_tools`                | boolean           |
  | `has_vision`               | boolean           |
  | `has_structured_output`    | boolean           |
  | `reasoning_effort`         | `low`/`medium`/`high` |
  | `agent_types`              | list of strings   |
  | `group_ids`                | list of uuids     |
  | `service_ids`              | list of uuids     |
  | `content_regex`            | regex that compiles |

  ## Actions

    * `force_use_case` — pin the request to one use case (`target_use_case_keys`
      must hold exactly one key).
    * `restrict_use_cases` — remove every other use case from the candidate
      set (`target_use_case_keys` must hold at least one key).

  Targets are use-case **keys**, not ids: a rule keeps working when a preset is
  dropped and reseeded.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions ~w(force_use_case restrict_use_cases)
  @efforts ~w(low medium high)

  @condition_keys ~w(min_tokens max_tokens has_tools has_vision
    has_structured_output reasoning_effort agent_types group_ids service_ids
    content_regex)

  @boolean_conditions ~w(has_tools has_vision has_structured_output)
  @integer_conditions ~w(min_tokens max_tokens)
  @string_list_conditions ~w(agent_types group_ids service_ids)

  schema "router_rules" do
    field :name, :string
    field :description, :string
    field :priority, :integer, default: 100
    field :enabled, :boolean, default: true
    field :match_conditions, :map, default: %{}
    field :action, :string
    field :target_use_case_keys, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name description priority enabled match_conditions action
    target_use_case_keys)a

  @required ~w(name action)a

  @doc "Valid rule actions."
  def actions, do: @actions

  @doc "Allow-listed `match_conditions` keys."
  def condition_keys, do: @condition_keys

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:action, @actions)
    |> unique_constraint(:name, name: :router_rules_name_unique_index)
    |> validate_match_conditions()
    |> validate_targets()
  end

  defp validate_match_conditions(changeset) do
    conditions =
      case get_field(changeset, :match_conditions) do
        conditions when is_map(conditions) -> conditions
        _ -> %{}
      end

    Enum.reduce(conditions, changeset, fn {key, value}, cs ->
      validate_condition(cs, to_string(key), value)
    end)
  end

  defp validate_condition(changeset, key, value) when key in @boolean_conditions do
    if is_boolean(value),
      do: changeset,
      else: add_condition_error(changeset, key, value, "must be true or false")
  end

  defp validate_condition(changeset, key, value) when key in @integer_conditions do
    if is_integer(value) and value >= 0,
      do: changeset,
      else: add_condition_error(changeset, key, value, "must be a non-negative integer")
  end

  defp validate_condition(changeset, "reasoning_effort", value) do
    if value in @efforts,
      do: changeset,
      else:
        add_condition_error(changeset, "reasoning_effort", value, "must be low, medium or high")
  end

  defp validate_condition(changeset, key, value) when key in @string_list_conditions do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: changeset,
      else: add_condition_error(changeset, key, value, "must be a list of strings")
  end

  defp validate_condition(changeset, "content_regex", value) when is_binary(value) do
    case Regex.compile(value) do
      {:ok, _regex} ->
        changeset

      {:error, _reason} ->
        add_condition_error(changeset, "content_regex", value, "must be a valid regex")
    end
  end

  defp validate_condition(changeset, key, value) when key in @condition_keys do
    add_condition_error(changeset, key, value, "has an unsupported value")
  end

  defp validate_condition(changeset, key, _value) do
    add_error(
      changeset,
      :match_conditions,
      "has an unknown condition #{inspect(key)} (allowed: #{Enum.join(@condition_keys, ", ")})"
    )
  end

  defp add_condition_error(changeset, key, value, expectation) do
    add_error(
      changeset,
      :match_conditions,
      "condition #{inspect(key)} #{inspect(value)} #{expectation}"
    )
  end

  defp validate_targets(changeset) do
    case get_field(changeset, :action) do
      "force_use_case" ->
        case get_field(changeset, :target_use_case_keys) || [] do
          [key] when is_binary(key) ->
            changeset

          _ ->
            add_error(
              changeset,
              :target_use_case_keys,
              "must hold exactly one use case key for force_use_case"
            )
        end

      "restrict_use_cases" ->
        case get_field(changeset, :target_use_case_keys) || [] do
          [_ | _] -> changeset
          _ -> add_error(changeset, :target_use_case_keys, "must hold at least one use case key")
        end

      _ ->
        changeset
    end
  end
end
