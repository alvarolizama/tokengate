defmodule Tokengate.SmartRouter.UseCase do
  @moduledoc """
  A SmartRouter specialty (`router_use_cases`).

  A use case is *what the work is* ("coding_implement", "data_heavy_finance"),
  never a model: the models that can serve it live one level down in
  `router_use_case_models`, each tagged with the effort tier it covers. That is
  what lets one specialty hold 2+ tiered destinations, a fallback, tags and its
  own prompt-saving knobs without repeating the description on every row.

  ## Knobs

    * Hard requirements (`requires_tools`, `requires_vision`,
      `requires_structured_output`) are pre-filters: a candidate that cannot
      honour them is discarded **before** any classifier runs, so the decision
      cannot land the request on a model that will reject it with a 400.
    * `critical_accuracy` inverts the tie-break (on a tie the critical
      destination wins instead of the cheap one); `allow_downgrade` lets a
      session be re-routed to a cheaper tier mid-task; `pin_session` keeps the
      session on the model that opened it (changing models invalidates the
      upstream prompt cache and breaks `reasoning_content` inside a tool loop).
    * Prompt-saving knobs: `keep_last_n_images`, `max_history_turns`,
      `compact_json` and `stale_tool_trim_threshold_pct`. `nil` means "use the
      gateway default".
    * `fallback_model_id` is per use case and optional. When nil, the router
      falls back to `router_configs.default_model_id`; that is why the column is
      `ON DELETE NILIFY ALL` — losing the fallback model must not delete the
      specialty.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Providers.Model

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Slugs are public (docs, rules, preset seeds): lowercase, digits, underscores.
  @key_format ~r/\A[a-z][a-z0-9_]*\z/

  schema "router_use_cases" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :tags, {:array, :string}, default: []

    field :requires_tools, :boolean, default: false
    field :requires_vision, :boolean, default: false
    field :requires_structured_output, :boolean, default: false

    field :critical_accuracy, :boolean, default: false
    field :allow_downgrade, :boolean, default: true
    field :pin_session, :boolean, default: true

    field :keep_last_n_images, :integer
    field :max_history_turns, :integer
    field :compact_json, :boolean, default: false
    field :stale_tool_trim_threshold_pct, :integer

    field :priority, :integer, default: 100
    field :enabled, :boolean, default: true

    belongs_to :fallback_model, Model, foreign_key: :fallback_model_id

    has_many :use_case_models, Tokengate.SmartRouter.UseCaseModel,
      foreign_key: :router_use_case_id

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(key name description tags requires_tools requires_vision
    requires_structured_output critical_accuracy allow_downgrade pin_session
    keep_last_n_images max_history_turns compact_json
    stale_tool_trim_threshold_pct priority enabled fallback_model_id)a

  @required ~w(key name)a

  @doc false
  def changeset(use_case, attrs) do
    use_case
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_format(:key, @key_format,
      message: "must be a lowercase slug (letters, digits and underscores)"
    )
    |> validate_number(:keep_last_n_images, greater_than: 0)
    |> validate_number(:max_history_turns, greater_than: 0)
    |> validate_number(:stale_tool_trim_threshold_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> unique_constraint(:key, name: :router_use_cases_key_unique_index)
    |> foreign_key_constraint(:fallback_model_id)
  end
end
