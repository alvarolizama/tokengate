defmodule Tokengate.Accounts.User do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @email_regex ~r/^[^\s]+@[^\s]+$/

  # Locales que la UI ofrece, según `:locales` de la config del backend Gettext.
  # Se lee en compilación para que el schema no dependa del módulo web en
  # runtime; cambiar la lista de idiomas exige recompilar, igual que el resto
  # de la config.
  @ui_locales Keyword.get(
                Application.compile_env(:tokengate, TokengateWeb.Gettext, []),
                :locales,
                ["en"]
              )

  # Virtual fields used during registration / password update.
  # Never persisted; consumed by the registration changeset.
  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :global_role, :string, default: "user"
    field :status, :string, default: "active"
    field :timezone, :string, default: "Etc/UTC"
    field :locale, :string, default: "en"
    field :google_id, :string
    field :avatar_url, :string

    # Límite mensual de gasto: nil = sin límite propio, 0 = cero (jamás
    # ilimitado). El único camino a ilimitado es `unlimited_spend`. Los
    # defaults de conc/RPM propios del usuario (null = sin propios) completan
    # el escalado group → user → service.
    field :monthly_spend_limit_usd, :decimal
    field :unlimited_spend, :boolean, default: false
    field :default_concurrency_limit, :integer
    field :default_rpm_limit, :integer

    # Virtual
    field :password, :string, virtual: true
    # Virtual: contraseña actual, exigida para autorizar un cambio de
    # contraseña propio (re-autenticación). Nunca se persiste.
    field :current_password, :string, virtual: true

    has_many :group_members, Tokengate.Accounts.GroupMember

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(email name password global_role status google_id avatar_url timezone monthly_spend_limit_usd unlimited_spend default_concurrency_limit default_rpm_limit)a

  # Campos de límites editables por admin (gasto mensual, unlimited, conc/RPM
  # propios). `changeset/2` y `admin_create_changeset/2` los castean vía
  # @permitted; `admin_update_changeset/2` los agrega explícitamente.
  @spend_fields ~w(monthly_spend_limit_usd unlimited_spend default_concurrency_limit default_rpm_limit)a

  @doc """
  Changeset for self-registration (sign-up). Requires email + password
  and enforces password complexity.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, @permitted)
    |> validate_required([:email, :password])
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
  end

  @doc """
  Changeset for admin-created users. Admin sets email, name, password,
  and global_role. Same validations as registration but role is settable.
  """
  def admin_create_changeset(user, attrs) do
    user
    |> cast(attrs, @permitted)
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
    |> validate_inclusion(:global_role, ~w(user admin))
    |> validate_inclusion(:status, ~w(active suspended))
    |> validate_number(:monthly_spend_limit_usd, greater_than_or_equal_to: 0)
    |> validate_number(:default_concurrency_limit, greater_than: 0)
    |> validate_number(:default_rpm_limit, greater_than: 0)
    |> put_password_hash()
  end

  @doc """
  Changeset for updating user profile (no password). Admin can change
  name, global_role, and status.
  """
  def admin_update_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :global_role, :status] ++ @spend_fields)
    |> validate_email()
    |> validate_inclusion(:global_role, ~w(user admin))
    |> validate_inclusion(:status, ~w(active suspended))
    |> validate_number(:monthly_spend_limit_usd, greater_than_or_equal_to: 0)
    |> validate_number(:default_concurrency_limit, greater_than: 0)
    |> validate_number(:default_rpm_limit, greater_than: 0)
  end

  @doc """
  Changeset for resetting a user's password (admin action).
  Only touches password_hash.
  """
  def reset_password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
    |> put_password_hash()
  end

  @doc """
  Changeset for creating/updating a user from Google OAuth data.
  Sets google_id, avatar_url, name, and email. Does NOT touch password_hash
  — existing users keep their password, new users get google_id only.
  """
  def google_oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :google_id, :avatar_url])
    |> validate_required([:email, :google_id])
    |> validate_email()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, @permitted)
    |> validate_required([:email])
    |> validate_email()
    |> validate_number(:monthly_spend_limit_usd, greater_than_or_equal_to: 0)
    |> validate_number(:default_concurrency_limit, greater_than: 0)
    |> validate_number(:default_rpm_limit, greater_than: 0)
  end

  @doc """
  Changeset for updating a user's timezone preference.
  Validates that the timezone is a known IANA timezone.
  """
  def timezone_changeset(user, attrs) do
    user
    |> cast(attrs, [:timezone])
    |> validate_required([:timezone])
    |> validate_timezone()
  end

  @doc """
  Changeset for the user's UI language (`users.locale`), set from the sidebar
  selector. Only locales in `@ui_locales` are accepted.
  """
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> validate_required([:locale])
    |> validate_inclusion(:locale, @ui_locales)
  end

  @doc """
  Changeset for a user changing their OWN password. Re-authenticates with
  `current_password` and validates the complexity of the new one.
  """
  def change_password_changeset(user, attrs) do
    user
    |> cast(attrs, [:current_password, :password])
    |> validate_required([:current_password, :password])
    |> validate_current_password()
    |> validate_password()
    |> put_password_hash()
  end

  defp validate_timezone(changeset) do
    changeset
    |> validate_change(:timezone, fn :timezone, tz ->
      case DateTime.now(tz) do
        {:ok, _} -> []
        {:error, _} -> [timezone: "zona horaria no válida"]
      end
    end)
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, fn
      nil -> nil
      email -> String.downcase(String.trim(email))
    end)
    |> validate_format(:email, @email_regex, message: "must be a valid email address")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 12, max: 72)
    |> validate_format(:password, ~r/[A-Za-z]/, message: "must contain a letter")
    |> validate_format(:password, ~r/[0-9]/, message: "must contain a digit")
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end

  # Re-autenticación: sin hash que comparar no hay sesión válida y el error
  # es genérico (no se filtra si el usuario tiene o no contraseña local).
  defp validate_current_password(changeset) do
    current = get_change(changeset, :current_password)
    hash = changeset.data.password_hash

    cond do
      not is_binary(current) ->
        add_error(changeset, :current_password, "cannot be empty")

      is_binary(hash) and Bcrypt.verify_pass(current, hash) ->
        changeset

      true ->
        add_error(changeset, :current_password, "no es correcta")
    end
  end
end
