defmodule Tokengate.Providers.CatalogSyncTest do
  @moduledoc """
  The boot self-heal for an empty MODEL mirror.

  Production ran without a model catalog: the model snapshot is the only one read
  at RUNTIME, its path was baked at compile time (absent inside the release), so
  the boot seed inserted nothing while providers and labs — embedded in the beam
  — loaded fine. An empty picker with no recovery until the weekly cron is the
  defect this pins: the boot must enqueue a refresh itself and say so.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.Providers.{
    CatalogModel,
    CatalogModelOffer,
    CatalogProvider,
    CatalogRefreshWorker,
    CatalogSync,
    CatalogSyncState
  }

  alias Tokengate.Providers.Provider
  alias Tokengate.Repo

  setup do
    # Oban is :manual in tests, so an enqueued job stays `available` in the
    # database instead of draining: clear leftovers before asserting on them.
    Repo.delete_all(from j in Oban.Job, where: j.worker == ^inspect(CatalogRefreshWorker))
    Repo.delete_all(CatalogModel)
    :ok
  end

  test "an empty model mirror enqueues a refresh and records why" do
    assert {:enqueued, {:ok, job}} = CatalogSync.request_refresh_if_model_mirror_empty()

    assert job.worker == inspect(CatalogRefreshWorker)

    assert %{"reason" => "empty_model_mirror"} = warning = hd(CatalogSyncState.get!().warnings)
    assert warning["key"] == "catalog_models"
  end

  test "a populated model mirror is left alone" do
    Repo.insert!(%CatalogModel{key: "openai/gpt-5", name: "gpt-5"})

    Repo.insert!(%CatalogModelOffer{
      provider_key: "openai",
      model_key: "openai/gpt-5",
      provider_model: "gpt-5"
    })

    assert :ok = CatalogSync.request_refresh_if_model_mirror_empty()

    refute Repo.exists?(from j in Oban.Job, where: j.worker == ^inspect(CatalogRefreshWorker))
  end

  test "a HALF-seeded mirror (models but no offers) also enqueues a refresh" do
    # A boot killed mid-seed (healthcheck timeout, redeploy) can leave exactly
    # this: models inserted, offers not. Counting only `catalog_models` treated
    # it as done and the picker then showed every model with zero providers.
    Repo.insert!(%CatalogModel{key: "openai/gpt-5", name: "gpt-5"})

    assert {:enqueued, {:ok, _job}} = CatalogSync.request_refresh_if_model_mirror_empty()
  end

  describe "code-owned providers" do
    test "a NON-empty mirror still gets them (a live instance never re-seeds)" do
      # `seed_if_empty/0` solo actúa con la tabla VACÍA. En la instancia que ya
      # está sirviendo tráfico la tabla nunca vuelve a estar vacía, así que un
      # proveedor que models.dev no publica no entraría jamás por esa puerta: su
      # fila tiene que venir de código en cada arranque.
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
