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
    CatalogRefreshWorker,
    CatalogSync,
    CatalogSyncState
  }

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
end
