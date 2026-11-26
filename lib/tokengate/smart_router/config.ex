defmodule Tokengate.SmartRouter.Config do
  @moduledoc """
  One SmartRouter configuration **version** (`router_configs`).

  Exactly one row is the **serving Default** (`is_default = true`, enforced by
  the partial unique index `router_configs_single_default_idx`). Every other
  row is a candidate version: a full copy of the configuration that can be
  edited, cloned, diffed, run as a **Shadow** (evaluated in parallel without
  serving) and promoted in one click through
  `Tokengate.SmartRouter.Versions`.

  `get/0` and `ensure!/0` keep returning the Default, so every reader written
  against the old singleton keeps working untouched; `get_version/1` opens one
  specific version.

  ## Fields

    * `name` / `description` — operator-facing identity of the version
      (`"Default (v1)"` for the row `ensure!/0` creates).
    * `is_default` — this row serves live traffic. At most one row may be
      `true` (partial unique index), and a version is promoted to it, never
      flipped by hand.
    * `shadow_enabled` / `shadow_sample_pct` — the version is evaluated in
      parallel against a deterministic sample of live requests
      (`phash2({config_id, session_or_subject}, 100) < pct`) and its would-be
      decision recorded in `router_shadow_evaluations`. A shadow **never**
      serves, never writes `SessionPin` and never touches `Budgets`. The
      Default cannot be a shadow of itself (CHECK
      `router_configs_default_not_shadow_check`).
    * `archived_at` — retired version: hidden from the list by default, cannot
      be promoted nor shadowed, and pruned from every switcher.
    * `enabled` — kill switch. `false` means the alias answers
      `503 router_disabled` before touching any provider, which is why shipping
      the table does not turn the router on. It is **global**: promotion
      preserves it from the outgoing Default instead of inheriting it from the
      candidate (`Versions.promote_to_default!/2`), so promoting a version can
      never flip the kill switch.
    * `policy` — how the final candidate is chosen (`cost_first`, `balanced`,
      `quality_first`, `latency_first`).
    * `decision_timeout_ms` / `decision_context_chars` — the classifier gets the
      last user message truncated to `decision_context_chars` and a short
      timeout; both requests (context and time) are bounded so the decision can
      never cost more than it saves.
    * `fast_path_max_tokens` — a trivial prompt below this size skips the
      classifier entirely.
    * `sticky_ttl_seconds` — how long a session stays pinned to the model that
      opened it (changing models mid-task invalidates the upstream prompt
      cache).
    * `lock_tool_loops` — never re-decide while a tool loop is open.
    * `charge_decision_to_subject` — whether the classifier's own cost is
      reserved against the subject (`router_decision_cost_usd` on the log
      carries the amount either way).
    * `decision_model_id` / `default_model_id` / `baseline_model_id` — optional
      pointers to `models`, all `ON DELETE NILIFY ALL`: losing a model falls
      back to the next link of the chain instead of bricking the config.
      `baseline_model_id` is global like `enabled` and survives promotion.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.Model
  alias Tokengate.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Sentinel id of the row `ensure!/0` creates (mirrored by the backfill in
  # `20261126132447_add_smart_router_versions_and_shadow`).
  @singleton_id "a750d0c0-0000-4000-8000-000000000001"

  @default_name "Default (v1)"

  @policies ~w(cost_first balanced quality_first latency_first)

  schema "router_configs" do
    field :name, :string, default: @default_name
    field :description, :string
    field :is_default, :boolean, default: false
    field :shadow_enabled, :boolean, default: false
    field :shadow_sample_pct, :integer, default: 100
    field :archived_at, :utc_datetime

    field :enabled, :boolean, default: false
    field :policy, :string, default: "balanced"
    field :decision_timeout_ms, :integer, default: 800
    field :decision_context_chars, :integer, default: 1200
    field :fast_path_max_tokens, :integer, default: 400
    field :sticky_ttl_seconds, :integer, default: 900
    field :lock_tool_loops, :boolean, default: true
    field :charge_decision_to_subject, :boolean, default: true

    belongs_to :decision_model, Model, foreign_key: :decision_model_id
    belongs_to :default_model, Model, foreign_key: :default_model_id
    belongs_to :baseline_model, Model, foreign_key: :baseline_model_id

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name description is_default shadow_enabled shadow_sample_pct archived_at
    enabled policy decision_timeout_ms decision_context_chars
    fast_path_max_tokens sticky_ttl_seconds lock_tool_loops
    charge_decision_to_subject decision_model_id default_model_id
    baseline_model_id)a

  @doc "Sentinel id of the row `ensure!/0` creates."
  @spec singleton_id() :: String.t()
  def singleton_id, do: @singleton_id

  @doc "Name every fresh Default carries."
  @spec default_name() :: String.t()
  def default_name, do: @default_name

  @doc "Valid selection policies."
  def policies, do: @policies

  @doc """
  The **serving Default** configuration, or `nil` when the router was never
  configured.

  Read path: the router must never insert while serving a request, so this
  never creates the row. Falls back to the sentinel id so a database whose row
  predates `is_default` (or whose flag is momentarily unset) keeps being read
  exactly as before.
  """
  @spec get() :: t() | nil
  def get do
    case get_default() do
      nil -> Repo.get(__MODULE__, @singleton_id)
      config -> config
    end
  end

  @doc """
  The row flagged `is_default = true`, or `nil`.

  Returns `nil` — never a raise — when the flag is momentarily absent, so
  callers can decide between falling back (`get/0`) and failing loudly
  (`Versions.get_default!/0`).
  """
  @spec get_default() :: t() | nil
  def get_default do
    Repo.one(from c in __MODULE__, where: c.is_default == true, limit: 1)
  end

  @doc """
  One version by id, `nil` when it does not exist.

  Read path used by the version management screens and by the Shadow evaluator;
  it never inserts.
  """
  @spec get_version(String.t() | nil) :: t() | nil
  def get_version(nil), do: nil
  def get_version(id), do: Repo.get(__MODULE__, id)

  @doc """
  Returns the Default version, creating it (disabled) if there is none.

  Idempotent: `ON CONFLICT DO NOTHING` makes a concurrent boot or a second seed
  run a no-op, and an existing Default is never overwritten (operator settings
  survive). Only when no row is flagged `is_default` does this insert the
  sentinel row as the Default — a promoted version is never duplicated.
  """
  @spec ensure!() :: t()
  def ensure! do
    case get() do
      %__MODULE__{} = config -> config
      nil -> insert_singleton!()
    end
  end

  defp insert_singleton! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      __MODULE__,
      [
        %{
          id: @singleton_id,
          name: @default_name,
          is_default: true,
          inserted_at: now,
          updated_at: now
        }
      ],
      # No conflict target on purpose: a concurrent `ensure!/0` (or a promoted
      # version landing `is_default = true` at the same instant) must be a
      # no-op, whichever unique index it collides with.
      on_conflict: :nothing
    )

    get() || Repo.get!(__MODULE__, @singleton_id)
  end

  @doc false
  def changeset(config, attrs) do
    config
    # Two casts on purpose. Every field but `name` uses Ecto's DEFAULT
    # `empty_values`, so a blank `description` / `*_model_id` normalises to
    # `nil` — a freshly cloned version that carries `""` then does not show a
    # phantom diff against its source (`""` vs `nil`).
    |> cast(attrs, @permitted -- [:name])
    # `name: ""` is different: it is REAL input and must be a validation error,
    # not silently "not provided". `empty_values: []` keeps the blank string so
    # `validate_format/3` can reject it.
    |> cast(attrs, [:name], empty_values: [])
    |> validate_required([:name])
    # `validate_required/2` only sees `nil`: with `empty_values: []` a blank
    # name survives the cast as `""`, so it is rejected here explicitly.
    |> validate_format(:name, ~r/\S/, message: "can't be blank")
    |> validate_inclusion(:policy, @policies)
    |> validate_number(:decision_timeout_ms, greater_than: 0)
    |> validate_number(:decision_context_chars, greater_than: 0)
    |> validate_number(:fast_path_max_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:sticky_ttl_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:shadow_sample_pct,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_not_default_and_shadow()
    |> unique_constraint(:is_default, name: :router_configs_single_default_idx)
    |> check_constraint(:is_default,
      name: :router_configs_default_not_shadow_check,
      message: "a version cannot be the Default and a shadow at the same time"
    )
    # The Default serves every request: an archived Default would leave the
    # router with no serving version (the flag and the retirement contradict
    # each other), so the database refuses that pair and the changeset turns
    # the refusal into a field error instead of a 500.
    |> check_constraint(:is_default,
      name: :router_configs_default_not_archived_check,
      message: "the Default version cannot be archived"
    )
    |> foreign_key_constraint(:decision_model_id)
    |> foreign_key_constraint(:default_model_id)
    |> foreign_key_constraint(:baseline_model_id)
  end

  # The Default serves every request; shadowing it against itself would double
  # every decision for a comparison that can only ever agree with itself.
  defp validate_not_default_and_shadow(changeset) do
    if get_field(changeset, :is_default) && get_field(changeset, :shadow_enabled) do
      add_error(
        changeset,
        :shadow_enabled,
        "cannot be enabled on the Default version"
      )
    else
      changeset
    end
  end
end
