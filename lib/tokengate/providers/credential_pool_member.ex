defmodule Tokengate.Providers.CredentialPoolMember do
  @moduledoc """
  Pertenencia de una credencial a un pool (`credential_pools`).

  El `provider_id` está denormalizado a propósito: las FKs compuestas
  `(pool_id, provider_id)` y `(credential_id, provider_id)` son las que
  impiden en la DB que un miembro mezcle un pool de un provider con una key de
  otro. Lo fija el contexto al agregar el miembro (se copia del pool), nunca
  el formulario.

  Una credencial entra una sola vez por pool
  (`credential_pool_members_pool_id_credential_id_unique_index`); la misma
  credencial sí puede vivir en pools distintos.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credential_pool_members" do
    belongs_to :pool, Tokengate.Providers.CredentialPool
    belongs_to :credential, Tokengate.Providers.Credential
    belongs_to :provider, Tokengate.Providers.Provider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(member, attrs) do
    # `provider_id` NO va en el cast: se copia del pool al insertar.
    member
    |> cast(attrs, [:pool_id, :credential_id])
    |> validate_required([:pool_id, :credential_id, :provider_id])
    |> unique_constraint([:pool_id, :credential_id],
      name: :credential_pool_members_pool_id_credential_id_unique_index,
      message: "this credential is already a member of the pool"
    )
    # Nombres de las FKs compuestas creadas por la migración; Ecto no las
    # deriva solo porque son de dos columnas.
    |> foreign_key_constraint(:pool_id,
      name: :credential_pool_members_pool_id_provider_id_fkey,
      message: "pool does not exist for this provider"
    )
    |> foreign_key_constraint(:credential_id,
      name: :credential_pool_members_credential_id_provider_id_fkey,
      message: "credential does not belong to the pool's provider"
    )
  end
end
