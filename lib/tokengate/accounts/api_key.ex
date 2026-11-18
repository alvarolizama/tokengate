defmodule Tokengate.Accounts.ApiKey do
  @moduledoc """
  API key unificada. `subject_type` distingue el dueño:
  `"member"` — key de un GroupMember (usuario en un perfil de límites);
  `"service"` — key de un Service.

  ## Lifecycle

    * **revocar** = emitir una key nueva y anular la anterior: la fila vieja
      queda con `status: "revoked"` (su hash sigue siendo el token presentado,
      así que el token muere) y la nueva fila nace `active` con hash nuevo.
      Las dos escrituras viven en una transacción (`Accounts.revoke_and_replace_api_key/1`).
    * **borrar** = soft-hide: `hidden_at` marca la fila como invisible en TODAS
      las superficies (listados del contexto, paneles, `spend_by_api_key/2`)
      sin borrarla, porque `request_logs.api_key_id` no tiene FK hacia esta
      tabla y la atribución histórica debe sobrevivir.

  `hidden_at` se setea programáticamente (nunca por `cast/3`: un form no puede
  resucitar ni ocultar filas).
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
    field :hidden_at, :utc_datetime

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
    # El maxlength del input es sólo cliente: el tope vive aquí (el form
    # inline de rename es posteable por socket).
    |> validate_length(:label, max: 64)
    |> validate_subject()
    |> unique_constraint(:key_hash)
    |> assoc_constraint(:group_member)
    |> assoc_constraint(:service)
    # `api_keys.user_id` es CASCADE (structure.sql): borrar un usuario arrastra
    # sus keys. Declararlo convierte una violación en changeset (flash) en vez
    # de Ecto.ConstraintError.
    |> assoc_constraint(:user)
  end

  @doc """
  Soft-hide changeset: marks the key as deleted without removing the row.

  Sets `hidden_at` and revokes the key in the same write — a hidden key must
  never authenticate again. Both fields are set programmatically (they are not
  castable), so this is the only path that hides a key.
  """
  @spec hide_changeset(t()) :: Ecto.Changeset.t()
  def hide_changeset(%__MODULE__{} = api_key, hidden_at \\ nil) do
    hidden_at = hidden_at || DateTime.utc_now() |> DateTime.truncate(:second)

    api_key
    |> change()
    |> put_change(:hidden_at, hidden_at)
    |> put_change(:status, "revoked")
  end

  # Exactamente un subject seteado y consistente con subject_type.
  #
  # La key es del **sujeto**: `"member"` = del usuario (`user_id`), con
  # `group_member_id` opcional para trazabilidad; `"service"` = del servicio.
  # Se acepta la forma vieja (`group_member_id` sin `user_id`) para no romper
  # fixtures ni datos históricos, pero la forma nueva es por `user_id`.
  defp validate_subject(changeset) do
    subject_type = get_field(changeset, :subject_type)
    user_id = get_field(changeset, :user_id)
    member_id = get_field(changeset, :group_member_id)
    service_id = get_field(changeset, :service_id)

    cond do
      subject_type == "member" and (user_id != nil or member_id != nil) ->
        changeset

      subject_type == "service" and service_id != nil ->
        changeset

      subject_type == "member" ->
        add_error(changeset, :user_id, "the member key needs an owner (user_id)")

      true ->
        add_error(changeset, :subject_type, "must match the assigned subject")
    end
  end
end
