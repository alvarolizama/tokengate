defmodule Tokengate.Providers.CatalogSyncTest do
  @moduledoc """
  El arranque materializa los proveedores que models.dev NO publica.

  `seed_if_empty/0` sólo actúa con la tabla VACÍA; en la instancia que ya sirve
  tráfico la tabla nunca vuelve a estar vacía, así que la fila del proveedor
  code-owned tiene que venir de código en CADA arranque y materializarse como
  builtin para llegar al picker de alta de proveedor.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.Providers.{
    CatalogProvider,
    CatalogSync
  }

  alias Tokengate.Providers.Provider
  alias Tokengate.Repo

  describe "code-owned providers" do
    test "a NON-empty mirror still gets them (a live instance never re-seeds)" do
      assert Repo.aggregate(CatalogProvider, :count) > 0

      assert :ok = CatalogSync.ensure_code_providers()

      row = Repo.get!(CatalogProvider, "surplus-intelligence")
      assert row.status == "active"
      assert row.name == "Surplus Intelligence"
      assert row.base_url == "https://api.surplusintelligence.ai/v1"
      assert row.fetched_at != nil
    end

    test "it materializes as a builtin, so it lands in the provider picker" do
      assert :ok = CatalogSync.ensure_code_providers()
      assert :ok = CatalogSync.materialize()

      provider = Repo.get_by(Provider, key: "surplus-intelligence")

      assert provider
      assert provider.source == "builtin"
      assert provider.dialect == "openai"
      assert provider.base_url == "https://api.surplusintelligence.ai/v1"
      assert provider.status == "active"
      assert "llm" in provider.capabilities
    end

    test "it is idempotent: a second run writes nothing" do
      assert :ok = CatalogSync.ensure_code_providers()
      first = Repo.get!(CatalogProvider, "surplus-intelligence")

      assert :ok = CatalogSync.ensure_code_providers()
      second = Repo.get!(CatalogProvider, "surplus-intelligence")

      assert second.fingerprint == first.fingerprint
      assert second.updated_at == first.updated_at
    end
  end
end
