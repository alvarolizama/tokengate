defmodule Tokengate.Logs.RequestLog do
  @moduledoc """
  A request log entry for an API request routed through TokenGate.

  This table is a native Postgres RANGE-partitioned table on `inserted_at`
  (daily granularity). It is **append-only**: the context only inserts and
  queries — never updates or deletes.

  ## Cost

  `provider_cost_usd` is the **only** cost field: the amount the upstream
  reported it charged for the request (typically `usage.cost` from
  OpenAI-compatible gateways). When the upstream doesn't report a cost and
  `billing_mode` is `included` (subscription / RPM-limited), the value is
  `0`. When the upstream doesn't report a cost and `billing_mode` is
  `pay_per_token`, the value is also `0` — honest fallback, no phantom
  costs derived from stale manual pricing tables.

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

    field :model_provider_id, :binary_id
    field :model_alias_id, :binary_id
    field :model_requested, :string
    field :model_responded, :string
    field :agent_type, :string, default: "unknown"
    field :status_code, :integer
    field :provider_status_code, :integer
    field :error_reason, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :provider_cost_usd, :decimal
    field :latency_ms, :integer
    field :ttft_ms, :integer
    field :streaming, :boolean, default: false
    field :think, :boolean, default: false
    field :effort, :string
    field :api_key_prefix, :string
    field :credential_name, :string

    belongs_to :team_member, Tokengate.Accounts.TeamMember,
      references: :id,
      foreign_key: :team_member_id,
      type: :binary_id

    belongs_to :provider, Tokengate.Providers.Provider,
      references: :id,
      foreign_key: :provider_id,
      type: :binary_id
  end

  @permitted ~w(team_member_id provider_id model_provider_id model_alias_id
    model_requested model_responded agent_type status_code provider_status_code
    error_reason prompt_tokens completion_tokens provider_cost_usd
    latency_ms ttft_ms streaming think effort api_key_prefix
    credential_name inserted_at)a

  @required ~w(team_member_id model_requested inserted_at)a

  @doc false
  def changeset(request_log, attrs) do
    request_log
    |> cast(attrs, @permitted)
    # Accept legacy `:cost_usd`/`:savings_usd`/`:estimated_cost_usd` keys in
    # attrs (from test fixtures and any external callers written before the
    # 2026-07-30 refactor) and fold them onto the single surviving column
    # `provider_cost_usd`. The first non-nil value wins; explicit
    # `provider_cost_usd` always takes precedence.
    |> merge_legacy_cost_keys(attrs)
    |> validate_required(@required)
  end

  defp merge_legacy_cost_keys(%Ecto.Changeset{} = cs, attrs) do
    case cs.changes do
      %{provider_cost_usd: _} ->
        cs

      _ ->
        for key <- [:cost_usd, :savings_usd, :estimated_cost_usd],
            value = Map.get(attrs, key),
            not is_nil(value),
            reduce: cs do
          acc -> put_change(acc, :provider_cost_usd, value)
        end
    end
  end
end
