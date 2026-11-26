defmodule Tokengate.SmartRouter.UseCaseModel do
  @moduledoc """
  A destination of a use case (`router_use_case_models`).

  Each row binds an existing catalogue **model** to a use case, tagged with the
  `effort_tier` it covers (`low | medium | high | any`), so a specialty can hold
  several tiered destinations instead of one flat model reference.

  The target is a `models` row, never a `model_providers` row: the lane,
  credential pool, circuit breaker and pricing are inherited from the catalogue
  the model is already bound to, so a destination adds zero duplication. The
  same model may appear in several use cases (and twice in one use case under
  different tiers) — the unique key is
  `(router_use_case_id, target_model_id, effort_tier)`.

  ## Flags vs. use-case requirements

  The use case declares what the work *needs*; the destination declares what
  *it* can do (`supports_tools`, `supports_vision`,
  `supports_structured_output`). The pre-filter keeps only destinations that
  satisfy every hard requirement, which is why the same model can be a valid
  destination for `writing` and an invalid one for `computer_use`.

  `min_confidence` is the classifier floor for this destination: when the
  classifier is less sure than that, the router steps **up** a tier instead of
  down.

  ## Delete semantics

  `target_model_id` is `ON DELETE RESTRICT`: deleting a model that a use case
  still binds must be an explicit operator decision. `Providers.delete_model/1`
  declares the constraint on its changeset, so the caller receives
  `{:error, %Ecto.Changeset{}}` instead of an `Ecto.ConstraintError`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Providers.Model

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `any` = the destination is acceptable for every tier of the use case.
  @effort_tiers ~w(low medium high any)
  @effort_overrides ~w(low medium high)

  schema "router_use_case_models" do
    belongs_to :use_case, Tokengate.SmartRouter.UseCase,
      foreign_key: :router_use_case_id,
      references: :id

    belongs_to :target_model, Model, foreign_key: :target_model_id

    field :effort_tier, :string, default: "any"
    field :effort_override, :string

    field :supports_tools, :boolean, default: false
    field :supports_vision, :boolean, default: false
    field :supports_structured_output, :boolean, default: false

    field :min_confidence, :decimal

    field :tags, {:array, :string}, default: []
    field :flags, :map, default: %{}
    field :priority, :integer, default: 100
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(router_use_case_id target_model_id effort_tier effort_override
    supports_tools supports_vision supports_structured_output min_confidence
    tags flags priority enabled)a

  @required ~w(router_use_case_id target_model_id)a

  @doc "Valid effort tiers of a binding (`any` covers every tier)."
  def effort_tiers, do: @effort_tiers

  @doc false
  def changeset(use_case_model, attrs) do
    use_case_model
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:effort_tier, @effort_tiers)
    |> normalize_blank(:effort_override)
    |> validate_inclusion(:effort_override, @effort_overrides)
    |> validate_number(:min_confidence,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1
    )
    |> unique_constraint([:router_use_case_id, :target_model_id, :effort_tier],
      name: :router_use_case_models_use_case_target_tier_unique_index
    )
    |> assoc_constraint(:use_case)
    |> foreign_key_constraint(:target_model_id,
      message: "the model is still assigned to a SmartRouter use case"
    )
  end

  # An empty effort override means "send the client's effort as-is": store nil,
  # so "unset" has exactly one representation (same rule as `Model`'s effort
  # policy and the admin selects).
  defp normalize_blank(changeset, field) do
    case get_change(changeset, field) do
      "" -> put_change(changeset, field, nil)
      _ -> changeset
    end
  end
end
