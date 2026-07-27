defmodule Tokengate.Accounts.User do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @email_regex ~r/^[^\s]+@[^\s]+$/

  # Virtual fields used during registration / password update.
  # Never persisted; consumed by the registration changeset.
  @derive {Jason.Encoder, only: [:id, :email, :name, :global_role, :status]}
  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :global_role, :string, default: "user"
    field :status, :string, default: "active"
    field :google_id, :string
    field :avatar_url, :string

    # Virtual
    field :password, :string, virtual: true

    has_many :team_members, Tokengate.Accounts.TeamMember

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(email name password global_role status google_id avatar_url)a

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
    |> put_password_hash()
  end

  @doc """
  Changeset for updating user profile (no password). Admin can change
  name, global_role, and status.
  """
  def admin_update_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :global_role, :status])
    |> validate_email()
    |> validate_inclusion(:global_role, ~w(user admin))
    |> validate_inclusion(:status, ~w(active suspended))
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
      nil -> changeset
      password -> put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end
end
