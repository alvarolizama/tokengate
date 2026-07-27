defmodule Tokengate.Logs.RequestLog do
  @moduledoc """
  A request log entry for an API request routed through TokenGate.

  This table is a native Postgres RANGE-partitioned table on `inserted_at`
  (daily granularity). It is **append-only**: the context only inserts and
  queries — never updates or deletes.

  ## Privacy

  This table **never** stores prompt or completion content — only metadata
  (token counts, costs, latency, status). No PII or request/response bodies
  are persisted here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "request_logs" do
    field :id, :binary_id, primary_key: true, autogenerate: true
    field :inserted_at, :utc_datetime, primary_key: true

    field :provider_id, :binary_id
    field :model_alias_id, :binary_id
    field :model_requested, :string
    field :model_responded, :string
    field :agent_type, :string, default: "unknown"
    field :status_code, :integer
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cost_usd, :decimal
    field :provider_cost_usd, :decimal
    field :savings_usd, :decimal
    field :estimated_cost_usd, :decimal
    field :latency_ms, :integer
    field :ttft_ms, :integer
    field :streaming, :boolean, default: false

    belongs_to :team_member, Tokengate.Accounts.TeamMember,
      references: :id,
      foreign_key: :team_member_id,
      type: :binary_id
  end

  @permitted ~w(team_member_id provider_id model_alias_id
    model_requested model_responded agent_type status_code prompt_tokens
    completion_tokens cost_usd provider_cost_usd savings_usd estimated_cost_usd
    latency_ms ttft_ms streaming inserted_at)a

  @required ~w(team_member_id model_requested inserted_at)a

  @doc false
  def changeset(request_log, attrs) do
    request_log
    |> cast(attrs, @permitted)
    |> validate_required(@required)
  end
end
