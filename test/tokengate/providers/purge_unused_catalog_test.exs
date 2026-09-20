defmodule Tokengate.Providers.PurgeUnusedCatalogTest do
  @moduledoc """
  Regresión del "Full reset" de Mantenimiento: la purga del catálogo borra
  SOLO lo que no sirve tráfico y conserva lo activo.
  """

  # `purge_unused_catalog/0` BORRA filas de models / providers / credentials a
  # nivel global, así que no puede correr en paralelo con el resto de la suite:
  # bajo la suite completa la purga y otro test se bloquean entre sí y Postgres
  # responde `40P01 deadlock_detected` (pasaba aislado, fallaba en el gate).
  use Tokengate.DataCase, async: false

  alias Tokengate.Providers
  alias Tokengate.Repo

  defp fixture_custom_provider(name, source \\ "custom") do
    {:ok, provider} =
      Providers.create_provider(%{name: name, base_url: "http://localhost:1", source: source})

    provider
  end

  test "borra modelos sin despliegue y proveedores sin credencial; conserva el resto" do
    # Proveedor ACTIVO: custom con credencial.
    active = fixture_custom_provider("Active #{System.unique_integer([:positive])}")

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: active.id,
        api_key_encrypted: "sk-#{System.unique_integer([:positive])}",
        status: "active"
      })

    # Modelo ACTIVO: con despliegue sobre la credencial del activo.
    {:ok, model_used} =
      Providers.create_model(%{
        name: "used-#{System.unique_integer([:positive])}",
        context_window: 128_000
      })

    {:ok, _mp} =
      Providers.create_model_provider(%{
        model_id: model_used.id,
        credential_id: credential.id,
        provider_model: "used",
        priority: 1,
        enabled: true
      })

    # Modelo HUÉRFANO: sin despliegue.
    {:ok, model_orphan} =
      Providers.create_model(%{
        name: "orphan-#{System.unique_integer([:positive])}",
        context_window: 128_000
      })

    # Proveedor HUÉRFANO: builtin (materializado por el catálogo) sin
    # credencial. El changeset bloquea la identidad de los builtin, así que
    # se inserta directo — simula una fila materializada por CatalogSync.
    orphan_provider =
      Repo.insert!(%Providers.Provider{
        name: "Orphan #{System.unique_integer([:positive])}",
        base_url: "http://localhost:1",
        source: "builtin",
        dialect: "openai"
      })

    # Proveedor custom SIN credencial pero CON despliegue vía otro provider:
    # no existe ese caso (el despliegue exige credencial) — el custom sin
    # credencial y sin despliegue es huérfano igual que los builtin.

    # Acceso otorgado sobre el modelo huérfano: sin despliegue, es config
    # muerta — debe irse EN CASCADA con el modelo (FK ON DELETE CASCADE).
    {:ok, group} =
      Tokengate.Accounts.create_group(%{name: "Purge #{System.unique_integer([:positive])}"})

    group_model =
      Repo.insert!(%Tokengate.Providers.GroupModel{
        group_id: group.id,
        model_id: model_orphan.id
      })

    result = Providers.purge_unused_catalog()

    assert result.models >= 1
    assert result.providers >= 1

    # Conservados.
    assert Providers.get_provider(active.id) != nil
    assert Providers.get_model(model_used.id) != nil

    # Purgados.
    assert Providers.get_model(model_orphan.id) == nil
    assert Providers.get_provider(orphan_provider.id) == nil

    # Sin huérfanos: el acceso al modelo borrado cayó en cascada.
    refute Repo.get(Tokengate.Providers.GroupModel, group_model.id)
  end
end
