defmodule Tokengate.Credits.Topup do
  @moduledoc """
  Un top-up de crédito — recarga extra de **un solo uso**, con expiración
  opcional contada desde su creación.

  Tiene exactamente un dueño: `user_id` o `service_id` (uno y solo uno,
  forzado por el check `credit_topups_exactly_one_subject` en la tabla).

  El monto se guarda en **USD** (`amount_usd`), la misma unidad que
  `request_logs.provider_cost_usd`.

    * `expires_in_days` nil ⇒ sin expiración (nunca vence).
    * `expires_in_days` presente ⇒ `expires_at` = creación + N días, calculado
      en el changeset al crear Y al editar (un `expires_at` explícito en el
      mismo submit gana).
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

  # Si `expires_in_days` viene en los cambios:
  #   - `nil` (el usuario eligió "Sin expiración") limpia `expires_at` (salvo que
  #     venga explícito), porque `get_change/2` no distingue «sin cambio» de «nil».
  #   - entero positivo: valida la lista permitida y recalcula `expires_at`.
  defp validate_expiration(changeset) do
    case fetch_change(changeset, :expires_in_days) do
      :error ->
        changeset

      {:ok, nil} ->
        if get_change(changeset, :expires_at),
          do: changeset,
          else: put_change(changeset, :expires_at, nil)

      {:ok, days} ->
        changeset
        |> validate_inclusion(:expires_in_days, @valid_days)
        |> put_expires_at(days)
    end
  end

  # La base es la CREACIÓN, no el submit: el hint de la UI dice "counted from
  # its creation", y así editar los días de un top-up existente es idempotente.
  # Antes esto miraba `get_field`, que refleja los DATOS: un top-up que ya tenía
  # `expires_at` ignoraba en silencio cualquier cambio de `expires_in_days` (el
  # flash decía éxito y la fecha seguía siendo la vieja).
  defp put_expires_at(changeset, days) do
    if get_change(changeset, :expires_at) do
      changeset
    else
      base = get_field(changeset, :inserted_at) || DateTime.utc_now()

      expires_at =
        base
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
