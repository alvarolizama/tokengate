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

  ## Version scope

  A use case belongs to exactly one configuration version
  (`router_config_id`, `ON DELETE DELETE ALL`): a clone carries its own copy of
  every specialty, so two versions of `coding_implement` never share knobs.
  The key is only unique **inside** a version
  (`router_use_cases_config_key_unique_index`).

  For backward compatibility with callers written against the global table,
  `changeset/2` attaches a use case that has no version yet to the Default
  (`Config.ensure!/0`). Nothing that predates versioning has to change.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Providers.Model
  alias Tokengate.SmartRouter.Config

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

    belongs_to :router_config, Config, foreign_key: :router_config_id

    belongs_to :fallback_model, Model, foreign_key: :fallback_model_id

    has_many :use_case_models, Tokengate.SmartRouter.UseCaseModel,
      foreign_key: :router_use_case_id

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(router_config_id key name description tags requires_tools requires_vision
    requires_structured_output critical_accuracy allow_downgrade pin_session
    keep_last_n_images max_history_turns compact_json
    stale_tool_trim_threshold_pct priority enabled fallback_model_id)a

  @required ~w(key name)a

  @doc false
  def changeset(use_case, attrs) do
    use_case
    |> cast(attrs, @permitted)
    |> put_default_router_config()
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
    |> unique_constraint([:router_config_id, :key],
      name: :router_use_cases_config_key_unique_index,
      error_key: :key
    )
    |> assoc_constraint(:router_config)
    |> foreign_key_constraint(:fallback_model_id)
  end

  # Backward compatibility: every caller written before versions existed built
  # a use case with no `router_config_id`. Attaching it to the Default keeps
  # those call sites, seeds and tests valid without a second argument.
  defp put_default_router_config(changeset) do
    if get_field(changeset, :router_config_id) do
      changeset
    else
      put_change(changeset, :router_config_id, Config.ensure!().id)
    end
  end
end
