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
  @derive {Jason.Encoder, only: [:id, :email, :name, :global_role]}
  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :global_role, :string, default: "user"

    # Virtual
    field :password, :string, virtual: true

    has_many :team_members, Tokengate.Accounts.TeamMember

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(email name password global_role)a
  @required ~w(email password)a

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
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
