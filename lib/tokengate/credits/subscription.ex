defmodule Tokengate.Credits.Subscription do
  @moduledoc """
  Una suscripción de crédito — la *policy* (config), no el saldo.

  Otorga `units` de crédito gastable por ciclo, opcionalmente recurrente
  (`recurrence = "monthly"`, anclada en `reset_day`) y con política de
  `rollover` (arrastrar un % del remanente, con tope opcional).

  El **grant** (la instancia con estado) es `(subscription, user)` y vive
  fuera de esta tabla: ver `Tokengate.Credits`.

    * `user_id == nil` ⇒ sub **de grupo** (uno o más grupos la referencian
      vía `groups.default_subscription_id`); un miembro de cualquiera de esos
      grupos queda auto-asignado al mismo grant.
    * `user_id` seteado ⇒ sub **directa** del usuario (o un top-up, cuando
      `recurrence = "none"`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @recurrences ~w(none monthly)
  @rollover_modes ~w(reset rollover)
  @statuses ~w(active paused)

  schema "credit_subscriptions" do
    belongs_to :user, Tokengate.Accounts.User

    field :name, :string
    field :units, :integer, default: 0
    field :recurrence, :string, default: "monthly"
    field :reset_day, :integer
    field :rollover_mode, :string, default: "reset"
    field :rollover_pct, :integer
    field :rollover_cap_units, :integer
    field :status, :string, default: "active"
    field :starts_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(user_id name units recurrence reset_day rollover_mode
                rollover_pct rollover_cap_units status starts_at expires_at)a

  @required ~w(units recurrence)a

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:recurrence, @recurrences)
    |> validate_inclusion(:rollover_mode, @rollover_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:units, greater_than_or_equal_to: 0)
    |> validate_number(:reset_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_number(:rollover_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:rollover_cap_units, greater_than_or_equal_to: 0)
    |> validate_monthly_fields()
    |> validate_rollover()
    |> assoc_constraint(:user)
  end

  # `reset_day` es obligatorio para suscripciones recurrentes.
  defp validate_monthly_fields(changeset) do
    if get_field(changeset, :recurrence) == "monthly" and
         is_nil(get_field(changeset, :reset_day)) do
      add_error(changeset, :reset_day, "es obligatorio para suscripciones mensuales")
    else
      changeset
    end
  end

  # `rollover` solo aplica a recurrentes y necesita un porcentaje.
  defp validate_rollover(changeset) do
    if get_field(changeset, :rollover_mode) == "rollover" do
      cond do
        get_field(changeset, :recurrence) != "monthly" ->
          add_error(changeset, :rollover_mode, "solo aplica a suscripciones mensuales")

        is_nil(get_field(changeset, :rollover_pct)) ->
          add_error(changeset, :rollover_pct, "es obligatorio en modo rollover")

        true ->
          changeset
      end
    else
      changeset
    end
  end

  @doc "Valores válidos de `recurrence`."
  def recurrences, do: @recurrences

  @doc "Valores válidos de `rollover_mode`."
  def rollover_modes, do: @rollover_modes

  @doc "Valores válidos de `status`."
  def statuses, do: @statuses

  @doc "¿La suscripción es un default de grupo (`user_id` nil)?"
  def group_scoped?(%__MODULE__{user_id: nil}), do: true
  def group_scoped?(%__MODULE__{}), do: false

  @doc "¿La suscripción es directa de un usuario?"
  def direct?(%__MODULE__{user_id: nil}), do: false
  def direct?(%__MODULE__{}), do: true
end
