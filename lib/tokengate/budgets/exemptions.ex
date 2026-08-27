defmodule Tokengate.Budgets.Exemptions do
  @moduledoc """
  CRUD + hot-path lookup for budget exemptions (`budget_exemptions` table).

  An exemption excludes a user, team or service from one of the daily
  spending caps (see `Tokengate.Budgets.Exemption` for the scope semantics).

  `exempt?/4` is called on the proxy pre-flight for every request — it does
  a tiny indexed `exists?` query per call, the same envelope the proxy
  already pays for `GlobalSettings.get_daily_cap/0` today. Escalation to a
  cached set can come later without changing call sites.
  """

  import Ecto.Query

  alias Tokengate.Budgets.Exemption
  alias Tokengate.Repo

  @valid_types ~w(user team service)

  @doc """
  Whether `subject` is exempt from `scope` for this request.

  `subject` is `%{type: "user", id: user_id}`, `%{type: "team", id: team_id}`
  or `%{type: "service", id: service_id}`. A team member inherits their
  team's exemptions: both `{"user", user_id}` and `{"team", team_id}` rows
  are checked for members (the UI offers the team alternative exactly so
  admins can exempt a whole team without touching each member).

  Unknown subject types are never exempt.
  """
  @spec exempt?(scope :: String.t(), map(), map() | nil) :: boolean()
  def exempt?(scope, subject, team_subject)

  def exempt?(scope, %{type: type, id: id}, team_subject) when type in @valid_types do
    field = Exemption.subject_field(type)

    exempt_query(scope, field, id) or
      (team_subject != nil and exempt_query(scope, :team_id, team_subject.id))
  end

  def exempt?(_scope, _subject, _team_subject), do: false

  defp exempt_query(scope, field, id) do
    from(e in Exemption,
      where:
        e.scope == ^scope and
          field(e, ^field) == ^id
    )
    |> Repo.exists?()
  end

  @doc "Lists exemptions for a scope, preloading the subject for display."
  @spec list_for_scope(String.t()) :: [Exemption.t()]
  def list_for_scope(scope) do
    from(e in Exemption,
      where: e.scope == ^scope,
      order_by: [asc: e.inserted_at],
      preload: [:user, :team, :service]
    )
    |> Repo.all()
  end

  @doc "Adds an exemption. Returns {:ok, exemption} or {:error, changeset}."
  @spec add(map()) :: {:ok, Exemption.t()} | {:error, Ecto.Changeset.t()}
  def add(attrs) do
    %Exemption{}
    |> Exemption.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Removes an exemption by id."
  @spec remove(binary()) :: {non_neg_integer(), nil}
  def remove(id) do
    from(e in Exemption, where: e.id == ^id)
    |> Repo.delete_all()
  end

  @doc "Label for an exemption's subject, for the admin UI."
  def subject_label(%Exemption{subject_type: "user", user: %{name: name, email: email}}) do
    "#{name} (#{email})"
  end

  def subject_label(%Exemption{subject_type: "team", team: %{name: name}}), do: "Equipo: #{name}"
  def subject_label(%Exemption{subject_type: "service", service: %{name: name}}), do: name
  def subject_label(_), do: "sujeto eliminado"
end
