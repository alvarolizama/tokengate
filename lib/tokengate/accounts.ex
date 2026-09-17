defmodule Tokengate.Accounts do
  @moduledoc """
  The Accounts context: groups, users, group members, services, and API keys.
  """

  import Ecto.Query
  alias Tokengate.Repo
  alias Tokengate.Logs.RequestLog

  alias Tokengate.Accounts.{
    ApiKey,
    ApiKeyCache,
    Service,
    ServiceSupervisor,
    Group,
    GroupMember,
    User
  }

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  def list_groups, do: Repo.all(Group)

  @doc """
  Mapa `%{group_id => name}` de todos los perfiles de límites — resolución de nombres
  para agregados que agrupan por id (evita joins extra en el GROUP BY).
  """
  def group_names_by_id do
    Repo.all(from g in Group, select: {g.id, g.name}) |> Map.new()
  end

  def get_group!(id), do: Repo.get!(Group, id)

  def get_group(id), do: Repo.get(Group, id)

  def create_group(attrs) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> invalidate_group_auth_cache(group.id)
  end

  def delete_group(%Group{} = group) do
    alias Tokengate.Providers.{GroupModel, GroupMemberExtraModel}

    group = Repo.preload(group, group_members: :api_key)

    Repo.transaction(fn ->
      # Delete group_models (FK group_id)
      from(t in GroupModel, where: t.group_id == ^group.id)
      |> Repo.delete_all()

      # Detach services. `services.group_id` is a legacy column (the Service
      # schema no longer has the field — services were decoupled from groups
      # in 20260914044359) but its FK is still ON DELETE RESTRICT, so it must
      # be cleared before the group can be deleted. Schemaless query because
      # the field is not part of the schema anymore.
      from(s in "services", where: s.group_id == type(^group.id, :binary_id))
      |> Repo.update_all(set: [group_id: nil])

      # For each group_member: delete api_key, extra_models, then the member
      for member <- group.group_members do
        if member.api_key, do: Repo.delete!(member.api_key)

        from(t in GroupMemberExtraModel, where: t.group_member_id == ^member.id)
        |> Repo.delete_all()

        member
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:group_member_id,
          name: "request_logs_group_member_id_fkey",
          message: "el miembro tiene logs de uso y no se puede eliminar"
        )
        |> Repo.delete()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end

      # Finally delete the group itself. Declare the residual FK constraints
      # so any unforeseen reference becomes a changeset error (surfaced to the
      # admin as a flash) instead of an Ecto.ConstraintError crash.
      group
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:id,
        name: "services_group_id_fkey",
        message: "el perfil de límites todavía tiene servicios asociados"
      )
      |> Ecto.Changeset.foreign_key_constraint(:id,
        name: "observability_destinations_group_id_fkey",
        message: "el perfil de límites todavía tiene destinos de observabilidad"
      )
      |> Repo.delete()
      |> case do
        {:ok, group} -> group
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> invalidate_group_auth_cache(group.id)
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    Group.changeset(group, attrs)
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

  @doc """
  Case-insensitive prefix email/name search for the member-add autocomplete.

  Security hardening (2026-08-08): requires at least 3 characters and matches
  only from the START of the email/name (no `%foo%` substring scan), so an
  admin cannot enumerate the whole users table with a one-character query.
  LIKE wildcards (`%` and `_`) in the input are escaped so a search for "%"
  returns no results.

  Returns up to `limit` (default 10) users whose email or name starts with
  the query (case-insensitive).
  """
  def search_users(query, limit \\ 10)
  def search_users(query, _limit) when byte_size(query) < 3, do: []

  def search_users(query, limit) when is_binary(query) do
    escaped =
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "#{String.downcase(escaped)}%"

    Repo.all(
      from u in User,
        where: ilike(u.email, ^pattern) or ilike(u.name, ^pattern),
        order_by: [asc: u.email],
        limit: ^limit
    )
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
    |> invalidate_user_auth_cache(user.id)
  end

  @doc """
  Permanently deletes a user and all associated data via DB-level
  CASCADE constraints:

  - group_members (CASCADE)
  - api_keys (CASCADE from group_members)
  - request_logs (CASCADE from group_members — ALL consumption history)
  - audit_logs (SET NULL — audit trail kept, attribution lost)

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def delete_user(%User{} = user) do
    user
    |> Repo.delete()
    |> invalidate_user_auth_cache(user.id)
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
    |> invalidate_user_auth_cache(user.id)
  end

  @doc """
  Updates a user's timezone preference. Returns `{:ok, user}` or
  `{:error, changeset}`.
  """
  def update_user_timezone(%User{} = user, timezone) when is_binary(timezone) do
    user
    |> User.timezone_changeset(%{timezone: timezone})
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
  Changeset (sin cambios) para el formulario de cambio de contraseña
  propio: valida en submit vía `change_password_changeset/2`, aquí solo
  prepara el `to_form`.
  """
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.change_password_changeset(user, attrs)
  end

  @doc """
  A user changes their OWN password: requires their current password
  (re-authentication) and validates the complexity of the new one.
  """
  def update_user_password(%User{} = user, attrs) do
    user
    |> User.change_password_changeset(attrs)
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
  # Group members
  # ---------------------------------------------------------------------------

  def get_group_member!(id), do: Repo.get!(GroupMember, id)

  def get_group_member(id), do: Repo.get(GroupMember, id)

  def get_group_member!(id, :with_assoc) do
    Repo.one!(
      from tm in GroupMember,
        where: tm.id == ^id,
        preload: [:user, :group, :api_key]
    )
  end

  def list_group_members_for_group(group_id) do
    Repo.all(from tm in GroupMember, where: tm.group_id == ^group_id, preload: [:user, :api_key])
  end

  @doc "Returns just the IDs of group members for a group (lightweight, no preloads)."
  def list_member_ids_for_group(group_id) do
    Repo.all(from tm in GroupMember, where: tm.group_id == ^group_id, select: tm.id)
  end

  def list_group_members_for_user(user_id) do
    Repo.all(from tm in GroupMember, where: tm.user_id == ^user_id, preload: [:group, :api_key])
  end

  @doc """
  Membresías (con perfil de límites y usuario precargados) de varios usuarios en una query:
  `%{user_id => [GroupMember, ...]}`. Para los tableros que resuelven el límite
  efectivo de cada usuario sin disparar una consulta por fila.
  """
  def list_users_with_memberships(user_ids) when is_list(user_ids) do
    members =
      Repo.all(
        from tm in GroupMember,
          where: tm.user_id in ^user_ids,
          preload: [:group, :user]
      )
      |> Enum.group_by(& &1.user_id)

    Map.new(user_ids, fn id -> {id, Map.get(members, id, [])} end)
  end

  @doc """
  Batch variant: returns a `%{user_id => [Group]}` map for a list of user ids
  in a single query (with groups preloaded), instead of one query per user.
  Users without memberships map to an empty list.
  """
  def list_groups_by_user_ids(user_ids) when is_list(user_ids) do
    members =
      Repo.all(
        from tm in GroupMember,
          where: tm.user_id in ^user_ids,
          preload: [:group]
      )

    grouped = Enum.group_by(members, & &1.user_id, & &1.group)

    Map.new(user_ids, fn id -> {id, Map.get(grouped, id, [])} end)
  end

  @doc """
  Resolves the group-member ids whose consumption a user is allowed to see.

    * admin — `nil` (org-wide, no filter)
    * user — ids of their own memberships only

  Used to scope analytics queries (dashboard, stats, CSV export) so
  non-admin users never see consumption outside their scope.
  """
  def scope_member_ids(%{global_role: "admin"}), do: nil

  def scope_member_ids(%{global_role: "user"} = user) do
    memberships = list_group_members_for_user(user.id)
    Enum.map(memberships, & &1.id)
  end

  def scope_member_ids(_), do: []

  @doc """
  Group ids a user is allowed to drill into: all for admins (`nil` =
  unrestricted), empty for non-admins.
  """
  def scope_group_ids(%{global_role: "admin"}), do: nil

  def scope_group_ids(%{global_role: "user"}), do: []

  def scope_group_ids(_), do: []

  @doc """
  Creates a group member. No API key is generated automatically;
  use `replace_api_key/1` to provision one.
  """
  def create_group_member(attrs) do
    %GroupMember{}
    |> GroupMember.changeset(attrs)
    |> Repo.insert()
  end

  def update_group_member(%GroupMember{} = group_member, attrs) do
    group_member
    |> GroupMember.changeset(attrs)
    |> Repo.update()
    |> invalidate_member_auth_cache(group_member.id)
  end

  def delete_group_member(%GroupMember{} = group_member) do
    alias Tokengate.Providers.GroupMemberExtraModel

    group_member = Repo.preload(group_member, :api_key)

    Repo.transaction(fn ->
      if group_member.api_key, do: Repo.delete!(group_member.api_key)

      from(t in GroupMemberExtraModel, where: t.group_member_id == ^group_member.id)
      |> Repo.delete_all()

      group_member
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:group_member_id,
        name: "request_logs_group_member_id_fkey",
        message: "el miembro tiene logs de uso y no se puede eliminar"
      )
      |> Repo.delete()
      |> case do
        {:ok, member} -> member
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> invalidate_member_auth_cache(group_member.id)
  end

  def change_group_member(%GroupMember{} = group_member, attrs \\ %{}) do
    GroupMember.changeset(group_member, attrs)
  end

  @doc """
  Mueve a un usuario a su sub mensual (`sub_id`), o lo deja sin sub cuando es
  `nil`. Invariante del modelo: **un usuario pertenece a una sola sub**.

  Mover no acumula: la membresía anterior se elimina primero (con su key, sus
  extras y su historial, por las FKs en cascada) y luego se crea la nueva. La
  sub anterior conserva sus logs ya exportados; el consumo del usuario pasa a
  contar contra la sub nueva.

  Devuelve `:ok` o `{:error, reason}`. Nada se toca si el usuario ya está en
  esa sub.
  """
  @spec sync_user_sub(term(), term() | nil) :: :ok | {:error, String.t()}
  def sync_user_sub(user_id, sub_id) do
    current = list_group_members_for_user(user_id)

    cond do
      sub_id == nil ->
        delete_memberships(current)

      Enum.any?(current, &(&1.group_id == sub_id)) ->
        :ok

      true ->
        case delete_memberships(current) do
          :ok ->
            case create_group_member(%{
                   user_id: user_id,
                   group_id: sub_id,
                   status: "active"
                 }) do
              {:ok, _member} -> :ok
              {:error, changeset} -> {:error, format_membership_errors(changeset)}
            end

          {:error, _} = error ->
            error
        end
    end
  end

  defp delete_memberships(memberships) do
    Enum.reduce_while(memberships, :ok, fn member, :ok ->
      case delete_group_member(member) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, "no se pudo quitar la membresía anterior"}}
      end
    end)
  end

  defp format_membership_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  # ---------------------------------------------------------------------------
  # API keys
  # ---------------------------------------------------------------------------

  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  def get_api_key(id), do: Repo.get(ApiKey, id)

  @doc """
  Looks up a group member by a presented API key token.

  La key es **del usuario** (N activas con label): se busca la key por hash y se
  resuelve la **membresía** de su `user_id` — el proxy sigue recibiendo un
  `GroupMember` y no cambia de forma. Un usuario pertenece a un solo perfil de límites, así
  que la membresía es única en la práctica; si hubiera varias se toma la
  primera por fecha de alta (determinista).

  Devuelve `{:error, :not_found}` cuando el token no corresponde a una key
  activa o su usuario no tiene membresía.
  """
  def get_group_member_by_api_key(token) when is_binary(token) do
    key_hash = hash_api_key(token)

    with %ApiKey{subject_type: "member"} = api_key <-
           Repo.one(
             from ak in ApiKey,
               where: ak.key_hash == ^key_hash and ak.status == "active",
               where: ak.subject_type == "member"
           ),
         %GroupMember{} = member <- member_for_key(api_key) do
      # La key resuelta viaja en la membresía: el proxy la usa para el
      # `api_key_id` del log y para el prefijo, sin volver a consultar.
      {:ok, %{member | api_key: api_key}}
    else
      _ -> {:error, :not_found}
    end
  end

  # La key es del usuario (`user_id`); las filas anteriores a la migración solo
  # tienen `group_member_id`, así que se acepta esa forma como respaldo.
  defp member_for_key(%ApiKey{user_id: user_id} = api_key) when is_binary(user_id) do
    Repo.one(
      from gm in GroupMember,
        where: gm.user_id == ^user_id,
        order_by: [asc: gm.inserted_at],
        limit: 1,
        preload: [:group, :user]
    )
    |> case do
      %GroupMember{} = member -> member
      nil -> nil
    end
    |> fallback_to_member_id(api_key)
  end

  defp member_for_key(%ApiKey{group_member_id: member_id}) when is_binary(member_id) do
    Repo.one(
      from gm in GroupMember,
        where: gm.id == ^member_id,
        preload: [:group, :user]
    )
  end

  defp member_for_key(_), do: nil

  defp fallback_to_member_id(nil, %ApiKey{group_member_id: member_id})
       when is_binary(member_id) do
    Repo.one(from gm in GroupMember, where: gm.id == ^member_id, preload: [:group, :user])
  end

  defp fallback_to_member_id(member, _api_key), do: member

  @doc """
  Revokes the existing API key for the group member and issues a new one,
  returning the new plaintext token.

  Because of the unique constraint on `group_member_id` (one active key per
  member), this replaces the key material in place: the old token is
  invalidated (its hash/prefix are overwritten) and a new token is
  generated. Returns `{:ok, api_key, new_token}` or `{:error, changeset}`.
  """
  def replace_api_key(%GroupMember{id: group_member_id} = group_member) do
    {new_token, new_hash, new_prefix} = generate_api_key_material()

    group_member = Repo.preload(group_member, [:api_key])
    old_hash = group_member.api_key && group_member.api_key.key_hash

    result =
      if group_member.api_key do
        group_member.api_key
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
          "subject_type" => "member",
          "group_member_id" => group_member_id,
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

    case result do
      {:ok, _api_key, _token} ->
        ApiKeyCache.invalidate_hash(old_hash)
        ApiKeyCache.invalidate_member(group_member_id)

      _ ->
        :ok
    end

    result
  end

  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.changeset(%{status: "revoked"})
    |> Repo.update()
    |> tap_invalidate_api_key(api_key)
  end

  @doc """
  Crea una API key. Acepta `label` y `user_id` (key de usuario, el caso nuevo)
  además de `service_id`. Devuelve `{:ok, api_key}` o `{:error, changeset}`.

  Cada key es independiente: un sujeto puede tener N activas con labels
  distintos. La invalidación cae por hash y por sujeto dueño.
  """
  def create_api_key(attrs) do
    %ApiKey{}
    |> ApiKey.changeset(attrs)
    |> Repo.insert()
    |> tap_invalidate_created_api_key()
  end

  # Keys activas de un usuario (con label), más recientes primero.
  @doc "Lista las keys activas de un usuario (N keys con label)."
  def list_api_keys_for_user(user_id) do
    Repo.all(
      from ak in ApiKey,
        where: ak.user_id == ^user_id and ak.status == "active",
        order_by: [desc: ak.inserted_at]
    )
  end

  @doc "Lista las keys activas de un servicio (N keys con label)."
  def list_api_keys_for_service(service_id) do
    Repo.all(
      from ak in ApiKey,
        where: ak.service_id == ^service_id and ak.status == "active",
        order_by: [desc: ak.inserted_at]
    )
  end

  @doc """
  Consumo por key desde los logs: `%{api_key_id => %{requests: n, cost_usd: Decimal}}`.

  Solo cuenta el histórico con `api_key_id` (las filas viejas se agrupan por
  `api_key_prefix`). `from` acota la ventana; `nil` = todo el histórico.
  """
  def spend_by_api_key(api_key_ids, from \\ nil) when is_list(api_key_ids) do
    query =
      from rl in RequestLog,
        where: rl.api_key_id in ^api_key_ids,
        group_by: rl.api_key_id,
        select:
          {rl.api_key_id, count(rl.id), fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)}

    query =
      if from do
        where(query, [rl], rl.inserted_at >= ^from)
      else
        query
      end

    query
    |> Repo.all()
    |> Map.new(fn {id, requests, cost} ->
      {id, %{requests: requests, cost_usd: Decimal.new(to_string(cost))}}
    end)
  end

  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.changeset(attrs)
    |> Repo.update()
  end

  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  @doc """
  Limpia las sticky routes de un **usuario** — todas sus keys, no una sola.

  Las sticky se llavean por `{api_key_hash, model_id}` y un usuario tiene N keys
  activas, así que limpiar «su» stickiness es limpiar la de todas ellas. Fuerza
  que su próxima petición re-evalúe proveedores en vez de quedarse pegado a uno
  degradado. Devuelve `:ok` sin keys o sin entradas.
  """
  def clear_user_sticky_routes(user_id) when is_binary(user_id) do
    user_id
    |> list_api_keys_for_user()
    |> Enum.map(& &1.key_hash)
    |> then(&Tokengate.Routing.StickyTracker.clear_all_for_api_key_hashes/1)

    :ok
  end

  @doc """
  Limpia las sticky routes de un **servicio** — todas sus keys.

  Un servicio tiene N keys activas con label, así que limpiar «su» stickiness es
  limpiar la de todas ellas. Devuelve `:ok` sin keys o sin entradas.
  """
  def clear_service_sticky_routes(service_id) when is_binary(service_id) do
    service_id
    |> list_api_keys_for_service()
    |> Enum.map(& &1.key_hash)
    |> then(&Tokengate.Routing.StickyTracker.clear_all_for_api_key_hashes/1)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Services
  # ---------------------------------------------------------------------------

  def get_service!(id), do: Repo.get!(Service, id)

  def get_service(id), do: Repo.get(Service, id)

  def list_services(limit \\ 500) do
    Repo.all(from s in Service, order_by: [asc: s.name], limit: ^limit)
  end

  def create_service(attrs) do
    %Service{}
    |> Service.changeset(attrs)
    |> Repo.insert()
  end

  def update_service(%Service{} = service, attrs) do
    service
    |> Service.changeset(attrs)
    |> Repo.update()
    |> invalidate_member_auth_cache(service.id)
  end

  def delete_service(%Service{} = service) do
    alias Tokengate.Providers.ServiceModel

    service = Repo.preload(service, [:api_key, :models])

    Repo.transaction(fn ->
      # Delete service_models
      from(sma in ServiceModel, where: sma.service_id == ^service.id)
      |> Repo.delete_all()

      # Delete api key
      if service.api_key, do: Repo.delete!(service.api_key)

      # Delete the service itself
      service
      |> Repo.delete()
      |> case do
        {:ok, service} -> service
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> invalidate_member_auth_cache(service.id)
  end

  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end

  # ---------------------------------------------------------------------------
  # Service API keys (tabla unificada api_keys, subject_type "service")
  # ---------------------------------------------------------------------------

  def get_service_api_key!(id), do: Repo.get!(ApiKey, id)

  def get_service_api_key(id), do: Repo.get(ApiKey, id)

  @doc """
  Looks up a service by a presented API key token.
  Returns `{:ok, service}` only when the token matches an active API key
  of subject_type "service". The returned service has `:api_key` preloaded.
  Returns `{:error, :not_found}` otherwise.
  """
  def get_service_by_api_key(token) when is_binary(token) do
    key_hash = hash_api_key(token)

    query =
      from s in Service,
        join: ak in assoc(s, :api_key),
        where:
          ak.key_hash == ^key_hash and ak.status == "active" and
            ak.subject_type == "service",
        preload: [:api_key]

    case Repo.one(query) do
      %Service{} = service -> {:ok, service}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Generates or replaces the API key for a service.
  Returns `{:ok, api_key, new_token}` or `{:error, changeset}`.
  """
  def generate_service_api_key(%Service{id: service_id} = service) do
    {new_token, new_hash, new_prefix} = generate_api_key_material()

    service = Repo.preload(service, [:api_key])
    old_hash = service.api_key && service.api_key.key_hash

    result =
      if service.api_key do
        service.api_key
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
          "subject_type" => "service",
          "service_id" => service_id,
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

    case result do
      {:ok, _api_key, _token} ->
        ApiKeyCache.invalidate_hash(old_hash)
        ApiKeyCache.invalidate_member(service_id)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Revokes the API key for a service.
  Returns `{:ok, api_key}` or `{:error, changeset}`.
  """
  def revoke_service_api_key(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.changeset(%{status: "revoked"})
    |> Repo.update()
    |> tap_invalidate_service_api_key(api_key)
  end

  # ---------------------------------------------------------------------------
  # Service supervisors
  # ---------------------------------------------------------------------------

  @doc """
  Adds a supervisor (user) to a service. Idempotent: when the pair already
  exists, returns `{:ok, existing}` instead of an error.

  Strategy: try the insert; if a unique-constraint violation fires on
  `[service_id, user_id]`, fetch and return the existing row. Any other
  changeset error is returned as `{:error, changeset}`.

  On success it broadcasts `{:supervisor_added, service_id}` on the user's
  topic, so a page the supervisor already has open picks up the new service
  without a reload.
  """
  def add_service_supervisor(service_id, user_id)
      when is_binary(service_id) and is_binary(user_id) do
    %ServiceSupervisor{}
    |> ServiceSupervisor.changeset(%{service_id: service_id, user_id: user_id})
    |> Repo.insert()
    |> case do
      {:ok, %ServiceSupervisor{} = supervisor} ->
        broadcast_supervisor_change(user_id, {:supervisor_added, service_id})
        {:ok, supervisor}

      {:error, changeset} ->
        if unique_violation_on_pair?(changeset) do
          {:ok, fetch_service_supervisor!(service_id, user_id)}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Removes a supervisor (user) from a service. Idempotent: returns
  `{:ok, :not_found}` if the pair doesn't exist, `{:ok, :removed}` otherwise.

  Removing the row is what revokes the supervisor's access to that service's
  read-only stats — so on an actual removal it broadcasts
  `{:supervisor_removed, service_id}` on the user's topic. Any LiveView of the
  supervised area for that user reacts in the same instant instead of waiting
  for the next navigation or socket reconnect.
  """
  def remove_service_supervisor(service_id, user_id)
      when is_binary(service_id) and is_binary(user_id) do
    case Repo.get_by(ServiceSupervisor, service_id: service_id, user_id: user_id) do
      nil ->
        {:ok, :not_found}

      %ServiceSupervisor{} = supervisor ->
        Repo.delete(supervisor)
        |> case do
          {:ok, _} ->
            broadcast_supervisor_change(user_id, {:supervisor_removed, service_id})
            {:ok, :removed}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  PubSub topic carrying the supervision changes of one user.

  Both events — `{:supervisor_added, service_id}` and
  `{:supervisor_removed, service_id}` — are published here, so the supervised
  area has a single subscription point per user.
  """
  def supervised_services_topic(user_id) when is_binary(user_id),
    do: "supervised_services:" <> user_id

  @doc """
  Whether the user supervises that service **right now**.

  This is the single source of truth for the read-only supervised area: access
  is granted by the `service_supervisors` row, never by the user's global role,
  so removing the row removes the access on the next mount (and in-flight
  views react through the PubSub broadcast).
  """
  def supervises_service?(user_id, service_id)
      when is_binary(user_id) and is_binary(service_id) do
    Repo.exists?(
      from ss in ServiceSupervisor,
        where: ss.user_id == ^user_id and ss.service_id == ^service_id
    )
  end

  def supervises_service?(_, _), do: false

  defp broadcast_supervisor_change(user_id, event) do
    Phoenix.PubSub.broadcast(
      Tokengate.PubSub,
      supervised_services_topic(user_id),
      event
    )
  end

  @doc """
  Lists the services a user supervises, preloaded with `:api_key`, ordered
  by name. Used to scope the supervisor's view of services.
  """
  def services_for_supervisor(user_id) when is_binary(user_id) do
    Repo.all(
      from s in Service,
        join: ss in assoc(s, :supervisors),
        where: ss.user_id == ^user_id,
        order_by: [asc: s.name],
        preload: [:api_key]
    )
  end

  @doc """
  Number of services a user supervises. Lightweight count (no joins, no
  preloads) used where only "does this user supervise anything?" matters —
  e.g. the sidebar entry for the read-only supervised view.
  """
  def count_services_for_supervisor(user_id) when is_binary(user_id) do
    Repo.one(
      from ss in ServiceSupervisor,
        where: ss.user_id == ^user_id,
        select: count(ss.id)
    )
  end

  def count_services_for_supervisor(_), do: 0

  @doc """
  Returns the user_ids (binary_ids) that supervise the given service.
  """
  def service_supervisor_ids(service_id) when is_binary(service_id) do
    Repo.all(
      from ss in ServiceSupervisor,
        where: ss.service_id == ^service_id,
        select: ss.user_id
    )
  end

  @doc """
  Returns the `%ServiceSupervisor{}` rows for a service with `:user` preloaded,
  for the admin management panel.
  """
  def service_supervisors(service_id) when is_binary(service_id) do
    Repo.all(
      from ss in ServiceSupervisor,
        where: ss.service_id == ^service_id,
        preload: [:user]
    )
  end

  defp fetch_service_supervisor!(service_id, user_id) do
    Repo.get_by!(ServiceSupervisor, service_id: service_id, user_id: user_id)
  end

  defp unique_violation_on_pair?(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      errors when is_list(errors) ->
        Enum.any?(errors, fn
          {:service_id, {_, opts}} when is_list(opts) ->
            Keyword.get(opts, :constraint) == :unique

          {:user_id, {_, opts}} when is_list(opts) ->
            Keyword.get(opts, :constraint) == :unique

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Effective limits
  # ---------------------------------------------------------------------------

  @doc """
  Computes the effective per-request limits for a **sujeto** with one rule,
  the same for usuario and servicio:

      propio || contenedor || default

  - **usuario (miembro)**: `user.default_concurrency_limit` /
    `user.default_rpm_limit` (propio) → `group.default_*` (contenedor) →
    default del módulo (5 conc / 60 rpm).
  - **servicio**: `service.concurrency_limit` / `service.rpm_limit` (propio)
    → default del módulo (5/60). Un servicio no tiene contenedor.

  Los límites son **absolutos, nunca aditivos**: el extra por miembro que se
  sumaba al default del perfil de límites ya no existe (migración
  `fold_member_extras_into_user` lo plegó al default propio del usuario).

  Spending is **not** here: budgets are credit subscriptions (`Tokengate.Credits`),
  enforced separately in the proxy.

  Service virtual members (GroupMember with the backing Service's id) are
  resolved to their Service limits so the proxy controller can use a single
  code path.
  """
  # Service virtual member — resolve the backing service for its absolute
  # limits.
  def effective_limits(%GroupMember{group: nil, id: id}) do
    case get_service(id) do
      %Service{} = service -> effective_limits(service)
      nil -> default_limits()
    end
  end

  # Service virtual member with its real group loaded: the limits live on
  # the backing Service, not on the virtual member, so delegate to the
  # Service branch.
  def effective_limits(%GroupMember{service_name: name} = member)
      when is_binary(name) do
    case get_service(member.id) do
      %Service{} = service -> effective_limits(service)
      nil -> effective_limits(%{member | service_name: nil})
    end
  end

  # Miembro sin precargar: se traen contenedor y dueño juntos.
  def effective_limits(%GroupMember{group: %Ecto.Association.NotLoaded{}} = group_member) do
    group_member = Repo.preload(group_member, [:group, :user])
    effective_limits(group_member)
  end

  def effective_limits(%GroupMember{user: %Ecto.Association.NotLoaded{}} = group_member) do
    group_member = Repo.preload(group_member, [:user])
    effective_limits(group_member)
  end

  # Miembro real: `propio` del usuario, si no `contenedor` del perfil de límites, si no el
  # default del módulo. `member_for_key/1` ya preloardea ambos.
  def effective_limits(%GroupMember{} = group_member) do
    %{
      concurrency_limit:
        resolve_limit(
          own_limit(group_member.user, :default_concurrency_limit),
          container_limit(group_member.group, :default_concurrency_limit),
          :concurrency_limit
        ),
      rpm_limit:
        resolve_limit(
          own_limit(group_member.user, :default_rpm_limit),
          container_limit(group_member.group, :default_rpm_limit),
          :rpm_limit
        )
    }
  end

  def effective_limits(%Service{} = service) do
    %{
      concurrency_limit: resolve_limit(service.concurrency_limit, nil, :concurrency_limit),
      rpm_limit: resolve_limit(service.rpm_limit, nil, :rpm_limit)
    }
  end

  # La regla única: propio, si no contenedor, si no default del módulo.
  defp resolve_limit(own, _container, _key) when is_integer(own), do: own

  defp resolve_limit(nil, container, _key) when is_integer(container), do: container

  defp resolve_limit(nil, nil, key), do: Map.fetch!(Service.default_limits(), key)

  # `:user` precargado → sus defaults propios; nil/NotLoaded → sin propio.
  defp own_limit(%User{} = user, field), do: Map.get(user, field)
  defp own_limit(_user, _field), do: nil

  # `:group` precargado → sus defaults; nil/NotLoaded → sin contenedor.
  defp container_limit(%Group{} = group, field), do: Map.get(group, field)
  defp container_limit(_group, _field), do: nil

  # Sujeto sin propio ni contenedor: solo el default del módulo.
  defp default_limits do
    %{
      concurrency_limit: Map.fetch!(Service.default_limits(), :concurrency_limit),
      rpm_limit: Map.fetch!(Service.default_limits(), :rpm_limit)
    }
  end

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

  # ---------------------------------------------------------------------------
  # API key auth cache — proxy hot path
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the auth entry (`%{member, limits}`) for a presented API key
  token, served from `Tokengate.Accounts.ApiKeyCache` on hits.

  Used by `TokengateWeb.Plugs.ApiAuth` — returns the entry map or `:error`
  for unknown/inactive keys. Errors are never cached so brute-force probes
  always pay a DB lookup and can't fill the cache with junk.
  """
  def resolve_auth_by_api_key(token) when is_binary(token) do
    key_hash = hash_api_key(token)

    ApiKeyCache.fetch(key_hash, fn ->
      build_auth_entry(token)
    end)
  end

  defp build_auth_entry(token) do
    case get_group_member_by_api_key(token) do
      {:ok, %GroupMember{} = member} ->
        %{member: member, limits: member_limits_with_plan(member), subject_type: "user"}

      _ ->
        case get_service_by_api_key(token) do
          {:ok, service} ->
            member =
              TokengateWeb.Plugs.ApiAuth.service_to_virtual_member(service)

            %{
              member: member,
              limits:
                Map.put(
                  effective_limits(service),
                  :credit_plan,
                  Tokengate.Credits.plan(service)
                ),
              subject_type: "service"
            }

          _ ->
            :error
        end
    end
  end

  # Effective limits + the resolved spend plan the member debits (monthly limit
  # + top-ups in draining order). Cached alongside the limits; staleness bounded
  # by the ApiKeyCache TTL.
  defp member_limits_with_plan(%GroupMember{} = member) do
    member
    |> effective_limits()
    |> Map.put(:credit_plan, Tokengate.Credits.plan(member))
  end

  # Invalidation helpers — piped after Repo writes that change auth-relevant
  # state. All are best-effort: the ETS table may not exist yet in early boot.
  defp invalidate_member_auth_cache({:ok, _} = result, member_id) do
    safe_invalidate(fn -> ApiKeyCache.invalidate_member(member_id) end)
    result
  end

  defp invalidate_member_auth_cache(result, _member_id), do: result

  defp invalidate_group_auth_cache({:ok, _} = result, group_id) do
    safe_invalidate(fn -> ApiKeyCache.invalidate_group(group_id) end)
    result
  end

  defp invalidate_group_auth_cache(result, _group_id), do: result

  # Los defaults propios del usuario (conc/RPM) son el primer eslabón de
  # `effective_limits/1`, y ese map viaja cacheado en cada entry de sus API
  # keys: editar el usuario debe tumbar todas sus entradas — no basta con la
  # invalidación por perfil de límites, que solo cubre el contenedor.
  defp invalidate_user_auth_cache({:ok, _} = result, user_id) do
    safe_invalidate(fn -> ApiKeyCache.invalidate_user(user_id) end)
    result
  end

  defp invalidate_user_auth_cache(result, _user_id), do: result

  defp tap_invalidate_api_key({:ok, _} = result, %ApiKey{} = key) do
    safe_invalidate(fn ->
      ApiKeyCache.invalidate_hash(key.key_hash)
      ApiKeyCache.invalidate_member(key.group_member_id)
    end)

    result
  end

  defp tap_invalidate_api_key(result, _key), do: result

  # Al crear una key hay que tumbar el cache por hash y por sujeto dueño: el
  # entry guarda la key resuelta y el plan, así que una key nueva (o el mismo
  # sujeto con otra key) no debe seguir sirviendo el entry viejo.
  defp tap_invalidate_created_api_key({:ok, %ApiKey{} = key} = result) do
    safe_invalidate(fn ->
      ApiKeyCache.invalidate_hash(key.key_hash)
      invalidate_key_subject(key)
    end)

    result
  end

  defp tap_invalidate_created_api_key(result), do: result

  defp invalidate_key_subject(%ApiKey{user_id: user_id}) when is_binary(user_id) do
    ApiKeyCache.invalidate_user(user_id)
  end

  defp invalidate_key_subject(%ApiKey{service_id: service_id}) when is_binary(service_id) do
    ApiKeyCache.invalidate_member(service_id)
  end

  defp invalidate_key_subject(%ApiKey{group_member_id: member_id}) when is_binary(member_id) do
    ApiKeyCache.invalidate_member(member_id)
  end

  defp invalidate_key_subject(_), do: :ok

  defp tap_invalidate_service_api_key({:ok, _} = result, %ApiKey{} = key) do
    safe_invalidate(fn ->
      ApiKeyCache.invalidate_hash(key.key_hash)
      ApiKeyCache.invalidate_member(key.service_id)
    end)

    result
  end

  defp tap_invalidate_service_api_key(result, _key), do: result

  defp safe_invalidate(fun) do
    if :ets.whereis(ApiKeyCache.table()) != :undefined, do: fun.()
    :ok
  end
end
