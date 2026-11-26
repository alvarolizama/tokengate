defmodule Tokengate.SmartRouter.Config do
  @moduledoc """
  The SmartRouter singleton configuration (`router_configs`).

  One row, enforced by the database (`router_configs_singleton_check` pins the
  id to `singleton_id/0`), so a double seed or a buggy insert cannot produce a
  second source of truth. `ensure!/0` is the idempotent way to obtain it and
  `get/0` the read path used by the router.

  ## Fields

    * `enabled` — kill switch. `false` means the alias answers
      `503 router_disabled` before touching any provider, which is why shipping
      the table does not turn the router on.
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
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Providers.Model
  alias Tokengate.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Sentinel id of the single row — mirrored by the migration's CHECK.
  @singleton_id "a750d0c0-0000-4000-8000-000000000001"

  @policies ~w(cost_first balanced quality_first latency_first)

  schema "router_configs" do
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

  @permitted ~w(enabled policy decision_timeout_ms decision_context_chars
    fast_path_max_tokens sticky_ttl_seconds lock_tool_loops
    charge_decision_to_subject decision_model_id default_model_id
    baseline_model_id)a

  @doc "Sentinel id of the singleton row (the migration enforces it)."
  @spec singleton_id() :: String.t()
  def singleton_id, do: @singleton_id

  @doc "Valid selection policies."
  def policies, do: @policies

  @doc """
  The configuration row, or `nil` when it was never created.

  Read path: the router must never insert while serving a request.
  """
  @spec get() :: t() | nil
  def get, do: Repo.get(__MODULE__, @singleton_id)

  @doc """
  Returns the singleton row, creating it disabled if it does not exist.

  Idempotent: `ON CONFLICT DO NOTHING` makes a concurrent boot or a second seed
  run a no-op, and an existing row is never overwritten (operator settings
  survive).
  """
  @spec ensure!() :: t()
  def ensure! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(__MODULE__, [%{id: @singleton_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )

    Repo.get!(__MODULE__, @singleton_id)
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, @permitted)
    |> validate_inclusion(:policy, @policies)
    |> validate_number(:decision_timeout_ms, greater_than: 0)
    |> validate_number(:decision_context_chars, greater_than: 0)
    |> validate_number(:fast_path_max_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:sticky_ttl_seconds, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:decision_model_id)
    |> foreign_key_constraint(:default_model_id)
    |> foreign_key_constraint(:baseline_model_id)
  end
end
