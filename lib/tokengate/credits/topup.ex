defmodule Tokengate.Credits.Topup do
  @moduledoc """
  Un top-up de crédito — recarga extra de **un solo uso**, con expiración
  opcional contada desde su creación.

  Tiene exactamente un dueño: `user_id` o `service_id` (uno y solo uno,
  forzado por el check `credit_topups_exactly_one_subject` en la tabla).

  El monto se guarda en **USD** (`amount_usd`), la misma unidad que
  `request_logs.provider_cost_usd`.

    * `expires_in_days` nil ⇒ sin expiración (nunca vence).
    * `expires_in_days` presente ⇒ `expires_at` se calcula en el changeset
      al crear (si `expires_at` viene explícito, se respeta).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_days [1, 3, 7, 14, 30, 60, 90]
  @statuses ~w(active exhausted expired revoked)

  schema "credit_topups" do
    belongs_to :user, Tokengate.Accounts.User
    belongs_to :service, Tokengate.Accounts.Service

    field :amount_usd, :decimal
    field :status, :string, default: "active"
    field :expires_in_days, :integer
    field :expires_at, :utc_datetime

    field :label, :string
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(user_id service_id amount_usd status expires_in_days
                expires_at label note)a

  @doc """
  Crea o actualiza un top-up. Valida monto positivo, status conocido,
  `expires_in_days` dentro de los valores permitidos y exactamente un
  dueño (`user_id` o `service_id`). Calcula `expires_at` desde
  `expires_in_days` cuando no viene explícito.
  """
  def changeset(topup, attrs) do
    topup
    |> cast(attrs, @permitted)
    |> validate_required([:amount_usd])
    |> validate_number(:amount_usd, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_expiration()
    |> validate_exactly_one_subject()
    |> check_constraint(:user_id,
      name: :credit_topups_exactly_one_subject,
      message: "must have exactly one owner (user or service)"
    )
    |> assoc_constraint(:user)
    |> assoc_constraint(:service)
  end

  # Si `expires_in_days` viene, debe estar en la lista permitida y fija
  # `expires_at` = ahora + N días (salvo que `expires_at` ya venga).
  defp validate_expiration(changeset) do
    case get_change(changeset, :expires_in_days) do
      nil ->
        changeset

      days ->
        changeset
        |> validate_inclusion(:expires_in_days, @valid_days)
        |> put_expires_at(days)
    end
  end

  defp put_expires_at(changeset, days) do
    if get_field(changeset, :expires_at) do
      changeset
    else
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(days * 86_400, :second)
        |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    end
  end

  # Exactamente un dueño: error en `:user_id` si hay 0 o 2.
  defp validate_exactly_one_subject(changeset) do
    owners =
      Enum.count([:user_id, :service_id], fn field ->
        not is_nil(get_field(changeset, field))
      end)

    if owners == 1 do
      changeset
    else
      add_error(changeset, :user_id, "must have exactly one owner (user or service)")
    end
  end

  @doc "Valores válidos de `expires_in_days`."
  def valid_days, do: @valid_days

  @doc "Valores válidos de `status`."
  def statuses, do: @statuses
end
