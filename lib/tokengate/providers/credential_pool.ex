defmodule Tokengate.Providers.CredentialPool do
  @moduledoc """
  Pool de credenciales de UN provider, montable como lane de un modelo.

  Un pool no aporta prioridad, `provider_model` ni precio: eso sigue siendo
  del lane (`Tokengate.Providers.ModelProvider`). El pool sólo agrupa keys del
  mismo provider para que el router rote entre ellas por request.

  El `provider_id` es la invariante dura: todos los miembros pertenecen a ese
  provider y la DB lo garantiza con las FKs compuestas de
  `credential_pool_members` (ver la migración `create_credential_pools`). Se
  fija al crear el pool y no se edita.

  Un pool es reusable: varios modelos del mismo provider pueden montarlo como
  lane, cada uno con su prioridad y su precio.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tokengate.Providers.{CredentialPoolMember, ModelProvider}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credential_pools" do
    field :name, :string

    belongs_to :provider, Tokengate.Providers.Provider
    has_many :members, CredentialPoolMember, foreign_key: :pool_id
    has_many :model_providers, ModelProvider, foreign_key: :pool_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pool, attrs) do
    # `provider_id` NO va en el cast: se fija programáticamente al crear el
    # pool (el provider es parte de su identidad, no un campo editable).
    pool
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> unique_constraint(:name, name: :credential_pools_provider_id_name_unique_index)
    |> foreign_key_constraint(:provider_id)
  end
end
