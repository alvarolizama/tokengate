defmodule Tokengate.Budgets.Exemption do
  @moduledoc """
  A budget exemption — a user, team or service excluded from one of the
  daily spending caps.

  `scope` selects which cap the subject is exempt from:

    * `"global_daily"` — the subject's spend never counts toward the global
      daily cap (`GlobalSettings.daily_max_spend_usd`).
    * `"user_daily"` — the subject ignores the per-user daily cap
      (`GlobalSettings.daily_max_per_user_usd`).

  The three subject FKs are mutually exclusive; which one applies is
  determined by `subject_type` (`"user"`, `"team"`, `"service"`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Accounts.{Service, Team, User}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(global_daily user_daily)
  @subject_types ~w(user team service)

  @subject_fields %{
    "user" => :user_id,
    "team" => :team_id,
    "service" => :service_id
  }

  schema "budget_exemptions" do
    field :scope, :string
    field :subject_type, :string
    field :note, :string

    belongs_to :user, User
    belongs_to :team, Team
    belongs_to :service, Service

    timestamps(type: :utc_datetime)
  end

  def changeset(exemption, attrs) do
    exemption
    |> cast(attrs, [:scope, :subject_type, :user_id, :team_id, :service_id, :note])
    |> validate_required([:scope, :subject_type])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_subject()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:service_id)
    |> unique_constraint(:user_id, name: :budget_exemptions_global_daily_user_unique)
    |> unique_constraint(:team_id, name: :budget_exemptions_global_daily_team_unique)
    |> unique_constraint(:service_id, name: :budget_exemptions_global_daily_service_unique)
    |> unique_constraint(:user_id, name: :budget_exemptions_user_daily_user_unique)
    |> unique_constraint(:team_id, name: :budget_exemptions_user_daily_team_unique)
    |> unique_constraint(:service_id, name: :budget_exemptions_user_daily_service_unique)
  end

  @doc "List of valid scopes."
  def scopes, do: @scopes

  @doc "List of valid subject types."
  def subject_types, do: @subject_types

  @doc "Maps a subject_type to its FK field (:user_id | :team_id | :service_id)."
  def subject_field(subject_type), do: Map.get(@subject_fields, subject_type)

  # Exactly one subject FK must be set, and it must match subject_type.
  defp validate_subject(changeset) do
    subject_type = get_field(changeset, :subject_type)
    field = subject_field(subject_type)

    case field do
      nil ->
        add_error(changeset, :subject_type, "inválido")

      field ->
        set_ids = Enum.count([:user_id, :team_id, :service_id], &get_field(changeset, &1))

        cond do
          is_nil(get_field(changeset, field)) ->
            add_error(changeset, field, "es obligatorio para este tipo de sujeto")

          set_ids > 1 ->
            add_error(changeset, :subject_type, "solo un sujeto por exención")

          true ->
            changeset
        end
    end
  end
end
