defmodule Tokengate.Accounts do
  @moduledoc """
  The Accounts context: teams, users, team members, and API keys.
  """

  import Ecto.Query

  alias Tokengate.Repo
  alias Tokengate.Accounts.{ApiKey, Team, TeamMember, User}

  # ---------------------------------------------------------------------------
  # Teams
  # ---------------------------------------------------------------------------

  def list_teams, do: Repo.all(Team)

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
    alias Tokengate.Providers.{TeamModelAlias, TeamMemberExtraAlias}

    team = Repo.preload(team, team_members: :api_key)

    Repo.transaction(fn ->
      # Delete team_model_aliases (FK team_id)
      from(t in TeamModelAlias, where: t.team_id == ^team.id)
      |> Repo.delete_all()

      # For each team_member: delete api_key, extra_aliases, then the member
      for member <- team.team_members do
        if member.api_key, do: Repo.delete!(member.api_key)

        from(t in TeamMemberExtraAlias, where: t.team_member_id == ^member.id)
        |> Repo.delete_all()

        member
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:team_member_id,
          name: "request_logs_team_member_id_fkey",
          message: "el miembro tiene logs de uso y no se puede eliminar"
        )
        |> Repo.delete()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end

      # Finally delete the team itself
      team
      |> Repo.delete()
      |> case do
        {:ok, team} -> team
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def change_team(%Team{} = team, attrs \\ %{}) do
    Team.changeset(team, attrs)
  end

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  @doc """
  Lists users ordered by most recently created, capped at `limit`
  (default 500) so the admin list can't grow unbounded in memory.
  """
  def list_users(limit \\ 500) do
    Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
  end

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
    |> User.admin_update_changeset(attrs)
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
  Admin-creates a user: sets email, name, password, global_role.
  Validates password complexity. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def admin_create_user(attrs) do
    %User{}
    |> User.admin_create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Admin-updates a user profile (name, global_role, status). Does NOT
  touch password — use `reset_user_password/2` for that.
  """
  def admin_update_user(%User{} = user, attrs) do
    user
    |> User.admin_update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Resets a user's password (admin action). Validates password complexity.
  """
  def reset_user_password(%User{} = user, attrs) do
    user
    |> User.reset_password_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Finds a user by their Google ID.
  """
  def get_user_by_google_id(google_id) when is_binary(google_id) do
    Repo.get_by(User, google_id: google_id)
  end

  @doc """
  Finds or creates a user from Google OAuth data.

  Flow:
    1. Look up by google_id — if found and active, return {:ok, user}.
    2. Look up by email — if found and active, link google_id and return {:ok, user}.
    3. If no user exists, return {:error, :not_found} (no auto-registration
       unless domain is in the allowlist, handled by the caller).

  Suspended users are rejected with {:error, :suspended}.
  """
  def find_or_create_from_google(%{
        google_id: google_id,
        email: email,
        name: name,
        avatar_url: avatar_url
      }) do
    normalized_email = String.downcase(String.trim(email))

    case get_user_by_google_id(google_id) do
      %User{status: "active"} = user ->
        {:ok, user}

      %User{status: "suspended"} ->
        {:error, :suspended}

      nil ->
        case get_user_by_email(normalized_email) do
          %User{status: "active"} = user ->
            user
            |> User.google_oauth_changeset(%{
              google_id: google_id,
              name: name || user.name,
              avatar_url: avatar_url
            })
            |> Repo.update()

          %User{status: "suspended"} ->
            {:error, :suspended}

          nil ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a new user from Google OAuth data (auto-registration).
  Called by the OAuth controller when the domain is in the allowlist.
  """
  def create_from_google(%{
        google_id: google_id,
        email: email,
        name: name,
        avatar_url: avatar_url
      }) do
    %User{}
    |> User.google_oauth_changeset(%{
      email: email,
      name: name,
      google_id: google_id,
      avatar_url: avatar_url,
      global_role: "user",
      status: "active"
    })
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success, `{:error, :unauthorized}` on bad credentials,
  or `{:error, :suspended}` when the account is suspended.

  Uses `no_user_verify/1` to remain timing-safe when the email is unknown.
  """
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    normalized = String.downcase(email)

    case Repo.get_by(User, email: normalized) do
      %User{status: "suspended"} ->
        {:error, :suspended}

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
  Resolves the team-member ids whose consumption a user is allowed to see.

    * admin — `nil` (org-wide, no filter)
    * manager — ids of every member of the teams they manage
    * user — ids of their own memberships only

  Used to scope analytics queries (dashboard, stats, CSV export) so
  non-admin users never see consumption outside their scope.
  """
  def scope_member_ids(%{global_role: "admin"}), do: nil

  def scope_member_ids(%{global_role: "user"} = user) do
    memberships = list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      from(tm in TeamMember, where: tm.team_id in ^manager_team_ids, select: tm.id)
      |> Repo.all()
    else
      Enum.map(memberships, & &1.id)
    end
  end

  def scope_member_ids(_), do: []

  @doc """
  Team ids a user is allowed to drill into: all for admins (`nil` =
  unrestricted), only managed teams for non-admins.
  """
  def scope_team_ids(%{global_role: "admin"}), do: nil

  def scope_team_ids(%{global_role: "user"} = user) do
    user.id
    |> list_team_members_for_user()
    |> Enum.filter(&(&1.team_role == "manager"))
    |> Enum.map(& &1.team_id)
    |> Enum.uniq()
  end

  def scope_team_ids(_), do: []

  @doc """
  Creates a team member. No API key is generated automatically;
  use `replace_api_key/1` or `generate_api_key/1` to provision one.
  """
  def create_team_member(attrs) do
    %TeamMember{}
    |> TeamMember.changeset(attrs)
    |> Repo.insert()
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

    if team_member.api_key do
      team_member.api_key
      |> ApiKey.changeset(%{
        "key_hash" => new_hash,
        "key_prefix" => new_prefix,
        "status" => "active"
      })
      |> Repo.update()
      |> case do
        {:ok, api_key} -> {:ok, api_key, new_token}
        {:error, changeset} -> {:error, changeset}
      end
    else
      %ApiKey{}
      |> ApiKey.changeset(%{
        "team_member_id" => team_member_id,
        "key_hash" => new_hash,
        "key_prefix" => new_prefix,
        "status" => "active"
      })
      |> Repo.insert()
      |> case do
        {:ok, api_key} -> {:ok, api_key, new_token}
        {:error, changeset} -> {:error, changeset}
      end
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

  - `daily_budget_usd`: team default + member's `extra_daily_budget_usd`
    (extra added when not nil). If the team default is `nil`, the result is
    `nil` (no limit) unless an extra is provided, in which case the result is
    just the extra.
  - `monthly_budget_usd`: team default + member's `extra_monthly_budget_usd`
    (extra added when not nil). If the team default is `nil`, the result is
    `nil` (no limit) unless an extra is provided, in which case the result is
    just the extra.
  - `concurrency_limit`: team default + member's `extra_concurrency` (when not
    nil). The team default is always present (defaults to 5).
  - `rpm_limit`: team's `default_rpm_limit` + member's `extra_rpm` (when not
    nil). The team default is always present (defaults to 60).

  Returns a map with `:daily_budget_usd`, `:monthly_budget_usd`,
  `:concurrency_limit`, and `:rpm_limit` keys.
  """
  def effective_limits(%TeamMember{} = team_member) do
    team_member = Repo.preload(team_member, [:team])
    team = team_member.team

    %{
      daily_budget_usd:
        combine_decimal(team.default_daily_budget_usd, team_member.extra_daily_budget_usd),
      monthly_budget_usd:
        combine_decimal(team.default_monthly_budget_usd, team_member.extra_monthly_budget_usd),
      concurrency_limit:
        combine_integer(team.default_concurrency_limit, team_member.extra_concurrency),
      rpm_limit: combine_integer(team.default_rpm_limit, team_member.extra_rpm)
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
