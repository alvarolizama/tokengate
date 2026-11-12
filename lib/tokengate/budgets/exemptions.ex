defmodule Tokengate.Budgets.Exemptions do
  @moduledoc """
  CRUD + hot-path lookup for budget exemptions (`budget_exemptions` table).

  An exemption excludes a user, limit profile or service from one of the daily
  spending caps (see `Tokengate.Budgets.Exemption` for the scope semantics).

  `exempt?/3` is called on the proxy pre-flight for every request. It used to
  run one or two `exists?` queries per call; now it answers from the set of
  exempt subjects cached in `Tokengate.Cache` under `{:exemptions, scope}`.

  The set is a `MapSet` of `{subject_field, id}` pairs (`{:user_id, id}`,
  `{:group_id, id}`, `{:service_id, id}`), so a lookup is a hash probe and an
  empty table caches as an empty set — a hit costs the same either way. Every
  mutation in this module invalidates the scope's key, so an admin change is
  visible on the next request; the TTL (45s) only bounds the staleness of a
  write that bypassed this context.
  """

  import Ecto.Query
  alias Tokengate.Budgets.Exemption
  alias Tokengate.Cache
  alias Tokengate.Repo

  @valid_types ~w(user group service)

  # Safety net only — `add/1` and `remove/1` invalidate the scope's key.
  @cache_ttl_ms :timer.seconds(45)

  @doc """
  Whether `subject` is exempt from `scope` for this request.

  `subject` is `%{type: "user", id: user_id}`, `%{type: "group", id: group_id}`
  or `%{type: "service", id: service_id}`. A profile member inherits their
  profile's exemptions: both `{"user", user_id}` and `{"group", group_id}` rows
  are checked for members (the UI offers the group alternative exactly so
  admins can exempt a whole profile without touching each member).

  Unknown subject types are never exempt.
  """
  @spec exempt?(scope :: String.t(), map(), map() | nil) :: boolean()
  def exempt?(scope, subject, group_subject)

  def exempt?(scope, %{type: type, id: id}, group_subject) when type in @valid_types do
    field = Exemption.subject_field(type)
    exempt_subjects = cached_subjects(scope)

    MapSet.member?(exempt_subjects, {field, id}) or
      (group_subject != nil and MapSet.member?(exempt_subjects, {:group_id, group_subject.id}))
  end

  def exempt?(_scope, _subject, _group_subject), do: false

  # One query per scope per TTL: the whole exemption set, not one `exists?` per
  # request. The empty table caches too — an installation without exemptions
  # pays the same (a single `[]`) as one that has them.
  defp cached_subjects(scope) do
    Cache.fetch({:exemptions, scope}, @cache_ttl_ms, fn -> load_subjects(scope) end)
  end

  defp load_subjects(scope) do
    from(e in Exemption,
      where: e.scope == ^scope,
      select: {e.subject_type, e.user_id, e.group_id, e.service_id}
    )
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn {type, user_id, group_id, service_id}, acc ->
      case Exemption.subject_field(type) do
        nil -> acc
        field -> MapSet.put(acc, {field, subject_id(field, user_id, group_id, service_id)})
      end
    end)
  end

  defp subject_id(:user_id, user_id, _group_id, _service_id), do: user_id
  defp subject_id(:group_id, _user_id, group_id, _service_id), do: group_id
  defp subject_id(:service_id, _user_id, _group_id, service_id), do: service_id

  defp invalidate_scope(scope) when is_binary(scope) do
    Cache.invalidate({:exemptions, scope})
  end

  defp invalidate_scope(_scope), do: :ok

  @doc "Lists exemptions for a scope, preloading the subject for display."
  @spec list_for_scope(String.t()) :: [Exemption.t()]
  def list_for_scope(scope) do
    from(e in Exemption,
      where: e.scope == ^scope,
      order_by: [asc: e.inserted_at],
      preload: [:user, :group, :service]
    )
    |> Repo.all()
  end

  @doc """
  Number of exemptions configured for a scope — e.g. how many users,
  limit profiles or services are exempt from the global daily cap. Display-only
  (the admin UI badge on the stats cards).
  """
  @spec count_for_scope(String.t()) :: non_neg_integer()
  def count_for_scope(scope) do
    from(e in Exemption, where: e.scope == ^scope)
    |> Repo.aggregate(:count)
  end

  @doc "Adds an exemption. Returns {:ok, exemption} or {:error, changeset}."
  @spec add(map()) :: {:ok, Exemption.t()} | {:error, Ecto.Changeset.t()}
  def add(attrs) do
    result =
      %Exemption{}
      |> Exemption.changeset(attrs)
      |> Repo.insert()

    with {:ok, exemption} <- result, do: invalidate_scope(exemption.scope)

    result
  end

  @doc "Removes an exemption by id."
  @spec remove(binary()) :: {non_neg_integer(), nil}
  def remove(id) do
    # The row's scope is read before deleting so only its key is dropped (the
    # cache has one entry per scope). Admin-path only — not a hot query.
    scope = Repo.one(from(e in Exemption, where: e.id == ^id, select: e.scope))

    result =
      from(e in Exemption, where: e.id == ^id)
      |> Repo.delete_all()

    if match?({count, _} when count > 0, result), do: invalidate_scope(scope)

    result
  end

  @doc "Label for an exemption's subject, for the admin UI."
  def subject_label(%Exemption{subject_type: "group", group: %{name: _}} = exemption),
    do: TokengateWeb.Gettext.translate("Limit profile") <> ": " <> subject_name(exemption)

  def subject_label(%Exemption{subject_type: type} = exemption) when type in ["user", "service"],
    do: subject_name(exemption)

  def subject_label(_), do: "sujeto eliminado"

  @doc """
  Bare subject text — no type prefix, so a table can show the type in its own
  column (`subject_type_label/1`).
  """
  def subject_name(%Exemption{subject_type: "user", user: %{name: name, email: email}}) do
    "#{name} (#{email})"
  end

  def subject_name(%Exemption{subject_type: "group", group: %{name: name}}), do: name
  def subject_name(%Exemption{subject_type: "service", service: %{name: name}}), do: name
  def subject_name(_), do: "sujeto eliminado"

  @doc "Display label for an exemption's subject type."
  def subject_type_label(%Exemption{subject_type: "user"}), do: "Usuario"

  def subject_type_label(%Exemption{subject_type: "group"}),
    do: TokengateWeb.Gettext.translate("Limit profile")

  def subject_type_label(%Exemption{subject_type: "service"}), do: "Servicio"
  def subject_type_label(_), do: "—"
end
