defmodule Tokengate.Accounts.ApiKey do
  @moduledoc """
  API key unificada. `subject_type` distingue el dueño:
  `"member"` — key de un GroupMember (usuario en un grupo);
  `"service"` — key de un Service.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :subject_type, :string, default: "member"
    belongs_to :group_member, Tokengate.Accounts.GroupMember
    belongs_to :service, Tokengate.Accounts.Service
    belongs_to :user, Tokengate.Accounts.User
    field :label, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(subject_type group_member_id service_id user_id label key_hash key_prefix status)a
  @required ~w(subject_type key_hash key_prefix)a

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:subject_type, ["member", "service"])
    |> validate_inclusion(:status, ["active", "revoked"])
    |> validate_subject()
    |> unique_constraint(:key_hash)
    |> assoc_constraint(:group_member)
    |> assoc_constraint(:service)
  end

  # Exactamente un subject seteado y consistente con subject_type.
  defp validate_subject(changeset) do
    subject_type = get_field(changeset, :subject_type)
    member_id = get_field(changeset, :group_member_id)
    service_id = get_field(changeset, :service_id)

    cond do
      subject_type == "member" and member_id != nil ->
        changeset

      subject_type == "service" and service_id != nil ->
        changeset

      true ->
        add_error(changeset, :subject_type, "debe coincidir con el subject asignado")
    end
  end
end
