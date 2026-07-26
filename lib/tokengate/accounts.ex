defmodule Tokengate.Accounts do
  @moduledoc """
  The Accounts context: organizations, teams, users, team members, and API keys.
  """

  import Ecto.Query

  alias Tokengate.Repo
  alias Tokengate.Accounts.{ApiKey, Organization, Team, TeamMember, User}

  # ---------------------------------------------------------------------------
  # Organizations
  # ---------------------------------------------------------------------------

  def list_organizations, do: Repo.all(Organization)

  def get_organization!(id), do: Repo.get!(Organization, id)

  def get_organization(id), do: Repo.get(Organization, id)

  def get_organization_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Organization, slug: slug)

  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def update_organization(%Organization{} = organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  def delete_organization(%Organization{} = organization) do
    Repo.delete(organization)
  end

  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  # ---------------------------------------------------------------------------
  # Teams
  # ---------------------------------------------------------------------------

  def list_teams, do: Repo.all(Team)

  def list_teams_for_organization(organization_id) do
    Repo.all(from t in Team, where: t.organization_id == ^organization_id)
  end

  def get_team!(id), do: Repo.get!(Team, id)

  def get_team(id), do: Repo.get(Team, id)

  def create_team(attrs) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  def update_team(%Team{} = team, attrs) do
    team
    |> Team.changeset(attrs)
    |> Repo.update()
  end

  def delete_team(%Team{} = team) do
    Repo.delete(team)
  end

  def change_team(%Team{} = team, attrs \\ %{}) do
    Team.changeset(team, attrs)
  end

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  def list_users, do: Repo.all(User)

  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @doc """
  Registers a new user. Hashes the password with Bcrypt and returns
  `{:ok, user}` or `{:error, changeset}`.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success or `{:error, :unauthorized}` on failure.
  Uses `no_user_verify/1` to remain timing-safe when the email is unknown.
  """
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    normalized = String.downcase(email)

    case Repo.get_by(User, email: normalized) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash) do
          {:ok, user}
        else
          {:error, :unauthorized}
        end

      _user ->
        Bcrypt.no_user_verify()
        {:error, :unauthorized}
    end
  end

  def authenticate_user(_email, _password), do: {:error, :unauthorized}

  # ---------------------------------------------------------------------------
  # Team members
  # ---------------------------------------------------------------------------

  def list_team_members, do: Repo.all(TeamMember)

  def get_team_member!(id), do: Repo.get!(TeamMember, id)

  def get_team_member(id), do: Repo.get(TeamMember, id)

  def get_team_member!(id, :with_assoc) do
    Repo.one!(
      from tm in TeamMember,
        where: tm.id == ^id,
        preload: [:user, :team, :api_key]
    )
  end

  def list_team_members_for_team(team_id) do
    Repo.all(from tm in TeamMember, where: tm.team_id == ^team_id, preload: [:user, :api_key])
  end

  def list_team_members_for_user(user_id) do
    Repo.all(from tm in TeamMember, where: tm.user_id == ^user_id, preload: [:team, :api_key])
  end

  @doc """
  Creates a team member and atomically provisions an API key in the same
  transaction. Returns `{:ok, team_member, api_key_token}` where the token
  is the plaintext API key (returned only this once).
  """
  def create_team_member(attrs) do
    {token, key_hash, key_prefix} = generate_api_key_material()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:team_member, fn _ ->
      %TeamMember{}
      |> TeamMember.changeset(attrs)
    end)
    |> Ecto.Multi.insert(:api_key, fn %{team_member: team_member} ->
      %ApiKey{}
      |> ApiKey.changeset(%{
        team_member_id: team_member.id,
        key_hash: key_hash,
        key_prefix: key_prefix,
        status: "active"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{team_member: tm, api_key: _api_key}} ->
        {:ok, tm, token}

      {:error, _failed_op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def update_team_member(%TeamMember{} = team_member, attrs) do
    team_member
    |> TeamMember.changeset(attrs)
    |> Repo.update()
  end

  def delete_team_member(%TeamMember{} = team_member) do
    alias Tokengate.Providers.TeamMemberExtraAlias

    team_member = Repo.preload(team_member, :api_key)

    Repo.transaction(fn ->
      if team_member.api_key, do: Repo.delete!(team_member.api_key)

      from(t in TeamMemberExtraAlias, where: t.team_member_id == ^team_member.id)
      |> Repo.delete_all()

      team_member
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:team_member_id,
        name: "request_logs_team_member_id_fkey",
        message: "el miembro tiene logs de uso y no se puede eliminar"
      )
      |> Repo.delete()
      |> case do
        {:ok, member} -> member
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def change_team_member(%TeamMember{} = team_member, attrs \\ %{}) do
    TeamMember.changeset(team_member, attrs)
  end

  # ---------------------------------------------------------------------------
  # API keys
  # ---------------------------------------------------------------------------

  def list_api_keys, do: Repo.all(ApiKey)

  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  def get_api_key(id), do: Repo.get(ApiKey, id)

  @doc """
  Looks up a team member by a presented API key token.

  Returns `{:ok, team_member}` only when the token matches an active API key.
  The returned team_member has `:team` and `:user` preloaded. Returns
  `{:error, :not_found}` otherwise.
  """
  def get_team_member_by_api_key(token) when is_binary(token) do
    key_hash = hash_api_key(token)

    query =
      from tm in TeamMember,
        join: ak in assoc(tm, :api_key),
        where: ak.key_hash == ^key_hash and ak.status == "active",
        preload: [:team, :user, :api_key]

    case Repo.one(query) do
      %TeamMember{} = tm -> {:ok, tm}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Revokes the existing API key for the team member and issues a new one,
  returning the new plaintext token.

  Because of the unique constraint on `team_member_id` (one key per member),
  this replaces the key material in place within a single transaction: the
  old token is invalidated (its hash/prefix are overwritten) and a new
  token is generated. Returns `{:ok, api_key, new_token}` or
  `{:error, changeset}`.
  """
  def replace_api_key(%TeamMember{id: team_member_id} = team_member) do
    {new_token, new_hash, new_prefix} = generate_api_key_material()

    team_member = Repo.preload(team_member, [:api_key])

    Ecto.Multi.new()
    |> Ecto.Multi.update(:api_key, fn _ ->
      # Mark the old key as revoked first (status transition), then in a
      # separate step we issue the replacement. Because there is a unique
      # constraint on team_member_id, we update the existing row in place
      # rather than inserting a new one.
      if team_member.api_key do
        team_member.api_key
        |> ApiKey.changeset(%{
          "key_hash" => new_hash,
          "key_prefix" => new_prefix,
          "status" => "active"
        })
      else
        %ApiKey{}
        |> ApiKey.changeset(%{
          "team_member_id" => team_member_id,
          "key_hash" => new_hash,
          "key_prefix" => new_prefix,
          "status" => "active"
        })
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{api_key: api_key}} ->
        {:ok, api_key, new_token}

      {:error, _failed_op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.changeset(%{status: "revoked"})
    |> Repo.update()
  end

  def create_api_key(attrs) do
    %ApiKey{}
    |> ApiKey.changeset(attrs)
    |> Repo.insert()
  end

  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.changeset(attrs)
    |> Repo.update()
  end

  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}) do
    ApiKey.changeset(api_key, attrs)
  end

  # ---------------------------------------------------------------------------
  # Effective limits
  # ---------------------------------------------------------------------------

  @doc """
  Computes the effective limits for a team member by combining team defaults
  with member overrides.

  - `daily_budget_usd` / `monthly_budget_usd`: team default + member's
    `extra_daily_budget_usd` (extra added when not nil). If the team default is
    `nil`, the result is `nil` (no limit) unless an extra is provided, in which
    case the result is just the extra.
  - `concurrency_limit`: team default + member's `extra_concurrency` (when not
    nil). The team default is always present (defaults to 5).
  - `rpm_limit`: team's `default_rpm_limit` (no member override). Always present
    (defaults to 60).

  Returns a map with `:daily_budget_usd`, `:monthly_budget_usd`,
  `:concurrency_limit`, and `:rpm_limit` keys.
  """
  def effective_limits(%TeamMember{} = team_member) do
    team_member = Repo.preload(team_member, [:team])
    team = team_member.team

    %{
      daily_budget_usd:
        combine_decimal(team.default_daily_budget_usd, team_member.extra_daily_budget_usd),
      monthly_budget_usd: team.default_monthly_budget_usd,
      concurrency_limit:
        combine_integer(team.default_concurrency_limit, team_member.extra_concurrency),
      rpm_limit: team.default_rpm_limit
    }
  end

  defp combine_decimal(nil, nil), do: nil
  defp combine_decimal(nil, extra), do: extra
  defp combine_decimal(base, nil), do: base
  defp combine_decimal(base, extra), do: Decimal.add(base, extra)

  defp combine_integer(base, nil), do: base
  defp combine_integer(nil, extra), do: extra
  defp combine_integer(base, extra), do: base + extra

  # ---------------------------------------------------------------------------
  # API key generation helpers
  # ---------------------------------------------------------------------------

  @doc """
  Generates API key material. Returns `{token, key_hash, key_prefix}` where:
  - `token` is the plaintext key shown to the user once ("tg-" <> base64url).
  - `key_hash` is the sha256 hex of the token (for storage/lookup).
  - `key_prefix` is the first 8 chars of the token (for display).
  """
  def generate_api_key_material do
    token = "tg-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    key_hash = hash_api_key(token)
    key_prefix = String.slice(token, 0, 8)
    {token, key_hash, key_prefix}
  end

  @doc """
  Computes the sha256 hex hash of an API key token for storage / lookup.
  """
  def hash_api_key(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end
end
