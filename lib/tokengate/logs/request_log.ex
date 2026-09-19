defmodule Tokengate.Logs.RequestLog do
  @moduledoc """
  A request log entry for an API request routed through TokenGate.

  This table is a native Postgres RANGE-partitioned table on `inserted_at`
  (daily granularity). It is **append-only** in normal operation: the
  context only inserts and queries — the single deliberate exception is
  `Tokengate.Logs.truncate_request_logs/0` (destructive maintenance
  TRUNCATE).

  ## Cost

  `provider_cost_usd` is the **only** cost field: the amount the upstream
  reported it charged for the request (typically `usage.cost` from
  OpenAI-compatible gateways). When the upstream doesn't report a cost and
  no manual pricing is configured, the value is `0` — honest fallback, no
  phantom costs derived from stale manual pricing tables.

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
    field :credential_id, :binary_id
    field :model_id, :binary_id
    # El usuario dueño de la fila, **en la fila**. Antes el sujeto solo se podía
    # reconstruir por `join` a `group_members`, que es una fila que el cambio de
    # sub borra en cascada; agregar por usuario era además más caro que agregar
    # por servicio (columna directa). Se puebla en la escritura (proxy →
    # `WriteWorker`) y en la DB (trigger + backfill de
    # `20260917033650_add_user_id_to_request_logs`). NULL en las filas de
    # servicio.
    field :user_id, :binary_id
    field :subject_type, :string, default: "user"
    field :model_requested, :string
    field :model_responded, :string
    field :agent_type, :string, default: "unknown"
    field :status_code, :integer
    field :provider_status_code, :integer
    field :error_reason, :string
    field :error_message, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0
    field :provider_cost_usd, :decimal
    field :latency_ms, :integer
    field :ttft_ms, :integer
    field :streaming, :boolean, default: false
    field :request_type, :string, default: "chat"
    field :think, :boolean, default: false
    field :effort, :string
    field :api_key_prefix, :string
    # La key que autenticó el request (NULL en el histórico: se agrupa por
    # `api_key_prefix`, que es el puente).
    field :api_key_id, :binary_id
    # Conversation-level cache affinity key (client session_id / hashed
    # conversation opening). NULL when no session could be derived.
    field :session_id, :string
    field :credential_name, :string
    field :client_agent, :string
    field :provider_key_prefix, :string

    belongs_to :group_member, Tokengate.Accounts.GroupMember,
      references: :id,
      foreign_key: :group_member_id,
      type: :binary_id

    belongs_to :service, Tokengate.Accounts.Service,
      references: :id,
      foreign_key: :service_id,
      type: :binary_id

    # `credit_subscription_id` se conserva como evidencia histórica del modelo
    # viejo (su tabla se dropeó), así que la columna se lee como binario crudo:
    # referenciarla como asociación apuntaría a un schema que ya no existe.
    field :credit_subscription_id, :binary_id

    # Qué top-up se debitó en este request (NULL = se debitó el límite del
    # sujeto, o no hubo débito). Convive con `credit_subscription_id`, que se
    # conserva como evidencia del modelo viejo.
    belongs_to :credit_topup, Tokengate.Credits.Topup,
      foreign_key: :credit_topup_id,
      type: :binary_id

    belongs_to :provider, Tokengate.Providers.Provider,
      references: :id,
      foreign_key: :provider_id,
      type: :binary_id
  end

  @permitted ~w(group_member_id user_id service_id subject_type provider_id model_provider_id credential_id model_id
    model_requested model_responded agent_type status_code provider_status_code
    error_reason error_message prompt_tokens completion_tokens cache_read_tokens
    cache_creation_tokens provider_cost_usd credit_subscription_id credit_topup_id
    latency_ms ttft_ms streaming request_type think effort api_key_prefix
    credential_name client_agent provider_key_prefix api_key_id inserted_at)a

  @required ~w(model_requested inserted_at subject_type)a

  # `request_logs.error_message` es `varchar(255)` pero el adapter recorta el
  # mensaje del vendor a 500: cuando el vendor devuelve un texto largo (Surplus
  # envuelve SU envelope de error en `message`, ~380 chars), el INSERT fallaba
  # entero con Postgrex 22001 (`string_data_right_truncation`) y la fila se
  # perdía entre reintentos de Oban — el rechazo desaparecía del dashboard y de
  # la página de Logs. Se recorta en el borde de datos (no en la respuesta al
  # cliente: ahí el detalle largo sirve para diagnosticar) para que TODOS los
  # caminos — éxito con fallback, error final, gate — queden cubiertos igual.
  @error_message_max_bytes 255

  @doc false
  def changeset(request_log, attrs) do
    request_log
    |> cast(attrs, @permitted)
    # Accept legacy `:cost_usd`/`:savings_usd`/`:estimated_cost_usd` keys in
    # attrs (from test fixtures and any external callers written before the
    # 2026-07-30 refactor) and fold them onto the single surviving column
    # `provider_cost_usd`. The keys are applied in list order, so the last
    # non-nil value wins; explicit `provider_cost_usd` always takes precedence.
    |> merge_legacy_cost_keys(attrs)
    |> clamp_error_message()
    |> validate_required(@required)
    |> validate_inclusion(:subject_type, ["user", "service"])
    |> validate_subject_id()
  end

  defp clamp_error_message(changeset) do
    update_change(changeset, :error_message, &clamp_bytes(&1, @error_message_max_bytes))
  end

  defp clamp_bytes(nil, _max), do: nil

  defp clamp_bytes(message, max) when is_binary(message) do
    if byte_size(message) <= max do
      message
    else
      # El marcador de recorte "…" ocupa 3 bytes en UTF-8: se descuentan del
      # presupuesto o el resultado vuelve a pasarse de la columna.
      truncate_to_bytes(message, max - byte_size("…")) <> "…"
    end
  end

  # Corta a `max` bytes y retrocede hasta el último límite de carácter válido:
  # `binary_part/3` a un offset crudo puede partir un multibyte y dejar UTF-8
  # inválido, que Postgres rechazaría igual (ahora por encoding).
  defp truncate_to_bytes(bin, max) do
    bin
    |> :binary.part(0, min(byte_size(bin), max))
    |> trim_invalid_tail()
  end

  defp trim_invalid_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_tail(:binary.part(bin, 0, byte_size(bin) - 1))
    end
  end

  # A log must reference its subject: `group_member_id` for users, `service_id`
  # for services. `group_member_id` is nullable at the DB level only so that
  # service rows can store a null — the relevant id is enforced here instead.
  defp validate_subject_id(changeset) do
    case get_field(changeset, :subject_type) do
      "user" -> validate_required(changeset, [:group_member_id])
      "service" -> validate_required(changeset, [:service_id])
      _ -> changeset
    end
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
