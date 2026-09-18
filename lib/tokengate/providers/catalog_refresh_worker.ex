defmodule Tokengate.Providers.CatalogRefreshWorker do
  @moduledoc """
  Refreshes the catalog mirrors from models.dev, asynchronously.

  Scheduled weekly (`Oban.Plugins.Cron`) and enqueueable on demand from the
  maintenance page. Steps:

    1. `GET https://models.dev/api.json` (providers AND their per-provider models)
       and `GET https://models.dev/models.json` (canonical models) with a 60s
       receive timeout and no Req-internal retries (Oban is the retry layer).
       The canonical payload is downloaded ONCE and feeds both the lab and the
       model half.
    2. Normalize PROVIDER-level fields for the mirror
       (`Catalog.normalize_providers/1`); the per-model half of the same payload
       goes to `ModelCatalog.derive/3` untouched.
    3. Upsert by `key` into `catalog_providers`, comparing fingerprints:
       unchanged rows are not written at all.
    4. Sweep rows upstream no longer publishes to `status: "stale"`. Never
       delete: a materialized `providers` row can be serving traffic.
    5. Re-run `CatalogSync.sync/0` so `providers` rows pick up the new identity
       immediately (no restart) — that is what makes a base URL fix land on a
       running instance.
    6. Upsert the LAB catalog derived from the same two payloads
       (`LabCatalog.derive/3`) into `labs`: insert/update by fingerprint, sweep
       the labs models.dev dropped to `stale`, and never touch a
       `source: "custom"` row. A lab fetch that fails is recorded as a warning
       and changes nothing (no lab is marked stale on a network error).
    7. Upsert the MODEL catalog — `catalog_models` (the model dimension) and
       `catalog_model_offers` (provider × model, with that provider's price) —
       from the same two payloads (`ModelCatalog.derive/3`). Only providers the
       gateway can serve contribute offers. An empty derivation is REFUSED, so a
       truncated payload can never sweep the whole model catalog stale.
    8. Record the outcome in `catalog_sync_state` (providers, labs and models)
       for the maintenance page.

  ## What it deliberately does NOT touch

  `providers` direct writes, `provider_credentials`, `model_providers`, the
  operator's own `models` rows, `source: "custom"` rows (providers AND labs), and
  a lab's `icon`: materialization is `CatalogSync`'s job and it skips customs, and
  the icon is operator-owned. Code customizations (`Catalog.@customizations`) are
  read-time overlays, so a refresh cannot remove them by construction.

  ## Base URL drift

  Upstream moving a builtin's base URL is APPLIED, and recorded as a warning in
  `catalog_sync_state.warnings` when that provider already has credentials —
  at that point live traffic silently changes destination, which the operator
  must see. A failed fetch records the error and marks NOTHING stale: a network
  outage must not degrade the catalog.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{
    Catalog,
    CatalogModel,
    CatalogModelOffer,
    CatalogProvider,
    CatalogSync,
    CatalogSyncState,
    Lab,
    LabCatalog,
    ModelCatalog,
    Provider
  }

  alias Tokengate.Repo

  @default_url "https://models.dev/api.json"
  @default_labs_url "https://models.dev/models.json"
  @source "models.dev"
  @topic "catalog:refresh"

  @doc "PubSub topic broadcast when a refresh finishes (manual or scheduled)."
  def topic, do: @topic

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case fetch(url()) do
      {:ok, providers_payload} ->
        entries = Catalog.normalize_providers(providers_payload)
        models_payload = fetch_models()

        {provider_counts, warnings} = apply_entries(entries)
        {lab_counts, warnings} = refresh_labs(models_payload, entries, warnings)

        {model_counts, warnings} =
          refresh_models(models_payload, providers_payload, entries, warnings)

        provider_counts
        |> Map.merge(lab_counts)
        |> Map.merge(model_counts)
        |> Map.put(:warnings, Enum.reverse(warnings))
        |> record()

        broadcast()
        :ok

      {:error, reason} ->
        record(%{error: reason})
        broadcast()
        {:error, reason}
    end
  end

  @doc "URL the refresh downloads (overridable in test via app env)."
  @spec url() :: String.t()
  def url, do: Application.get_env(:tokengate, :catalog_refresh_url, @default_url)

  @doc """
  URL the lab and model catalogs are derived from: models.dev's canonical model
  list.

  Defaults to the SAME origin as `url/0`, so pointing the refresh at a mirror
  (or at a test server) moves both halves together; `:labs_refresh_url`
  overrides the lab half alone.
  """
  @spec labs_url() :: String.t()
  def labs_url do
    Application.get_env(:tokengate, :labs_refresh_url) ||
      models_url_of(url()) ||
      @default_labs_url
  end

  @doc """
  True when a refresh job is queued or running — the maintenance page renders
  the button in a busy state instead of enqueuing a second one.

  Oban stores the worker as `inspect/1` of the module (no `Elixir.` prefix),
  so the comparison must use the same rendering.
  """
  @spec in_flight?() :: boolean()
  def in_flight? do
    from(j in Oban.Job,
      where: j.worker == ^inspect(__MODULE__),
      where: j.state in ["available", "scheduled", "executing", "retryable"],
      limit: 1
    )
    |> Repo.exists?()
  rescue
    # The Oban schema may be unavailable in a partially migrated database.
    _ -> false
  end

  ## Fetch ------------------------------------------------------------------

  defp fetch(url) do
    case Req.get(url,
           receive_timeout: 60_000,
           retry: false,
           headers: [{"user-agent", "tokengate-catalog-refresh"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        decode(body)

      {:ok, %{status: status}} ->
        {:error, "models.dev respondió #{status}"}

      {:error, exception} ->
        {:error, "no se pudo descargar el catálogo: #{Exception.message(exception)}"}
    end
  end

  # The canonical payload is fetched once per run and shared by the lab half and
  # the model half; each half reports its own warning when it failed.
  defp fetch_models, do: fetch(labs_url())

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "el catálogo no tiene el formato esperado"}
      {:error, _} -> {:error, "el catálogo no es JSON válido"}
    end
  end

  defp decode(_), do: {:error, "el catálogo no tiene el formato esperado"}

  # `https://models.dev/api.json` → `https://models.dev/models.json`, for any
  # origin (a mirror, or the test server). nil when the URL carries no origin.
  defp models_url_of(providers_url) when is_binary(providers_url) do
    case URI.parse(providers_url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        %{uri | path: "/models.json", query: nil, fragment: nil} |> URI.to_string()

      _ ->
        nil
    end
  end

  defp models_url_of(_), do: nil

  ## Apply ------------------------------------------------------------------

  defp apply_entries(entries) do
    # FIRST: the code-owned rows (providers models.dev does not publish). They
    # have to be in the mirror BEFORE it is read here, so `existing` is complete
    # and the sweep below sees their real status.
    CatalogSync.ensure_code_providers()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing = Repo.all(CatalogProvider) |> Map.new(&{&1.key, &1})

    {inserted, updated, unchanged, warnings} =
      Enum.reduce(entries, {0, 0, 0, []}, fn entry, {inserted, updated, unchanged, warnings} ->
        fingerprint = CatalogProvider.fingerprint(entry)

        attrs =
          Map.merge(entry, %{
            fingerprint: fingerprint,
            fetched_at: now,
            status: "active"
          })

        case Map.get(existing, entry.key) do
          nil ->
            %CatalogProvider{}
            |> CatalogProvider.changeset(attrs)
            |> Repo.insert!()

            {inserted + 1, updated, unchanged, warnings}

          %CatalogProvider{fingerprint: ^fingerprint, status: "active"} ->
            {inserted, updated, unchanged + 1, warnings}

          %CatalogProvider{} = row ->
            warnings = drift_warnings(row, entry, warnings)

            row
            |> CatalogProvider.changeset(attrs)
            |> Repo.update!()

            {inserted, updated + 1, unchanged, warnings}
        end
      end)

    {stale, warnings} = mark_stale(existing, entries, now, warnings)

    # Materialize immediately so a base URL fix (or a brand new provider) is
    # live without a restart. Materialize ONLY: seeding is the boot path's job
    # (see `CatalogSync`), or the snapshot would win over the payload this run
    # just downloaded and the counters below would describe the wrong writer.
    CatalogSync.materialize()

    counts = %{
      synced_at: now,
      source: @source,
      inserted: inserted,
      updated: updated,
      unchanged: unchanged,
      stale: stale,
      error: nil
    }

    {counts, warnings}
  end

  # Providers that vanished upstream: marked, never deleted.
  defp mark_stale(existing, entries, now, warnings) do
    upstream_keys = MapSet.new(entries, & &1.key)

    # Los code-owned NO son datos que desaparecieron: son datos que models.dev
    # nunca tuvo. Barrerlos a `stale` los dejaría congelados —`materialize/1`
    # salta las filas stale— y la página de mantenimiento los reportaría como
    # `already_stale` en cada refresh.
    code_owned = MapSet.new(Catalog.code_provider_keys())

    gone =
      existing
      |> Map.values()
      |> Enum.filter(
        &(&1.status == "active" and not MapSet.member?(upstream_keys, &1.key) and
            not MapSet.member?(code_owned, &1.key))
      )

    Enum.each(gone, fn row ->
      row
      |> CatalogProvider.changeset(%{status: "stale", fetched_at: now})
      |> Repo.update!()
    end)

    warnings =
      Enum.reduce(gone, warnings, fn row, acc ->
        case credential_count(row.key) do
          0 ->
            acc

          count ->
            [
              %{
                "key" => row.key,
                "name" => row.name,
                "reason" => "already_stale",
                "credentials" => count
              }
              | acc
            ]
        end
      end)

    {length(gone), warnings}
  end

  # A builtin's base URL moved upstream while it already had credentials:
  # applied (the gateway follows upstream) but surfaced, because live traffic
  # changed destination.
  defp drift_warnings(%CatalogProvider{} = row, entry, warnings) do
    new_base = Catalog.base_url(entry)

    with true <- not is_nil(new_base),
         true <- not is_nil(row.base_url),
         true <- new_base != row.base_url,
         count when count > 0 <- credential_count(entry.key) do
      [
        %{
          "key" => entry.key,
          "name" => entry.name,
          "reason" => "base_url_changed",
          "from" => row.base_url,
          "to" => new_base,
          "credentials" => count
        }
        | warnings
      ]
    else
      _ -> warnings
    end
  end

  defp credential_count(key) do
    from(p in Provider,
      join: c in assoc(p, :credentials),
      where: p.key == ^key,
      select: count(c.id)
    )
    |> Repo.one()
  end

  ## Labs -------------------------------------------------------------------

  # The lab catalog is derived from the SAME run: the canonical model list
  # (`/models.json`) plus the provider names just downloaded. A failure here is
  # a warning, not an error — the provider half already landed, and a network
  # error must not mark a single lab stale.
  defp refresh_labs(models_payload, provider_entries, warnings) do
    names = Map.new(provider_entries, &{&1.key, &1.name})

    case models_payload do
      {:error, reason} ->
        {labs_counts(0, 0, 0), [labs_warning("labs_fetch_failed", reason) | warnings]}

      {:ok, payload} ->
        case LabCatalog.derive(payload, names) do
          [] ->
            # A payload that derives no lab is not a model list (models.dev
            # publishes hundreds): refuse to apply it instead of sweeping every
            # lab in the catalog to stale.
            {labs_counts(0, 0, 0),
             [
               labs_warning(
                 "labs_payload_empty",
                 "el catálogo de labs vino sin labs; no se tocó ninguna fila"
               )
               | warnings
             ]}

          entries ->
            apply_labs(entries, warnings)
        end
    end
  end

  defp labs_warning(reason, message) do
    %{"reason" => reason, "message" => message}
  end

  defp apply_labs(entries, warnings) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    existing =
      from(l in Lab, where: l.source == "builtin")
      |> Repo.all()
      |> Map.new(&{&1.key, &1})

    # The lab half has no `unchanged` counter (there is nothing to materialize
    # and nothing to skip), so the count is tracked only to keep the reduce
    # honest.
    {inserted, updated, _unchanged} =
      Enum.reduce(entries, {0, 0, 0}, fn entry, {inserted, updated, unchanged} ->
        fingerprint = Lab.fingerprint(entry)

        attrs = %{
          name: entry.name,
          logo_url: entry.logo_url,
          model_count: entry.model_count,
          last_released: entry.last_released,
          last_updated: entry.last_updated,
          fingerprint: fingerprint,
          fetched_at: now,
          status: "active"
        }

        case Map.get(existing, entry.key) do
          nil ->
            %Lab{}
            |> Ecto.Changeset.change(key: entry.key, source: "builtin")
            |> Lab.remote_changeset(attrs)
            |> Repo.insert!()

            {inserted + 1, updated, unchanged}

          %Lab{fingerprint: ^fingerprint, status: "active"} ->
            {inserted, updated, unchanged + 1}

          %Lab{} = lab ->
            lab
            |> Lab.remote_changeset(attrs)
            |> Repo.update!()

            {inserted, updated + 1, unchanged}
        end
      end)

    stale = mark_labs_stale(existing, entries, now)

    {labs_counts(inserted, updated, stale), warnings}
  end

  defp labs_counts(inserted, updated, stale) do
    %{labs_inserted: inserted, labs_updated: updated, labs_stale: stale}
  end

  # Labs models.dev no longer publishes: marked, never deleted, and only among
  # builtin rows — a custom lab is not upstream's to drop.
  defp mark_labs_stale(existing, entries, now) do
    upstream_keys = MapSet.new(entries, & &1.key)

    gone =
      existing
      |> Map.values()
      |> Enum.filter(&(&1.status == "active" and not MapSet.member?(upstream_keys, &1.key)))

    Enum.each(gone, fn lab ->
      lab
      |> Lab.remote_changeset(%{status: "stale", fetched_at: now})
      |> Repo.update!()
    end)

    length(gone)
  end

  ## Models -----------------------------------------------------------------

  # The model mirror: the model dimension (`catalog_models`) plus the fact that
  # a provider serves it (`catalog_model_offers`), both derived from the same two
  # payloads the run already downloaded. Nothing here is materialized into the
  # operator's tables — the picker reads these rows and the operator decides.
  defp refresh_models(models_payload, providers_payload, provider_entries, warnings) do
    case models_payload do
      {:error, reason} ->
        {empty_model_counts(), [models_warning("models_fetch_failed", reason) | warnings]}

      {:ok, payload} ->
        %{models: models, offers: offers} =
          ModelCatalog.derive(provider_entries, providers_payload, payload)

        # An empty derivation is not a model list: refuse it instead of sweeping
        # ~3000 models (and every offer) stale on a truncated or partial payload.
        if models == [] and offers == [] do
          {empty_model_counts(),
           [
             models_warning(
               "models_payload_empty",
               "el catálogo de models vino vacío; no se tocó ninguna fila"
             )
             | warnings
           ]}
        else
          apply_models(models, offers, warnings)
        end
    end
  end

  defp models_warning(reason, message) do
    %{"reason" => reason, "message" => message}
  end

  # Zeroed counters for a run that wrote nothing (a failed or refused payload).
  defp empty_model_counts do
    %{
      models_inserted: 0,
      models_updated: 0,
      models_stale: 0,
      offers_inserted: 0,
      offers_updated: 0,
      offers_stale: 0
    }
  end

  defp apply_models(models, offers, warnings) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {model_inserted, model_updated} = upsert_models(models, now)
    model_stale = mark_models_stale(models, now)

    {offer_inserted, offer_updated} = upsert_offers(offers, now)
    offer_stale = mark_offers_stale(offers, now)

    Logger.debug(
      "[catalog refresh] models: #{length(models)} model(s), #{length(offers)} offer(s)"
    )

    counts = %{
      models_inserted: model_inserted,
      models_updated: model_updated,
      models_stale: model_stale,
      offers_inserted: offer_inserted,
      offers_updated: offer_updated,
      offers_stale: offer_stale
    }

    {counts, warnings}
  end

  defp upsert_models(models, now) do
    existing = Repo.all(CatalogModel) |> Map.new(&{&1.key, &1})

    Enum.reduce(models, {0, 0}, fn attrs, {inserted, updated} ->
      fingerprint = CatalogModel.fingerprint(attrs)
      full = Map.merge(attrs, %{fingerprint: fingerprint, fetched_at: now, status: "active"})

      case Map.get(existing, attrs.key) do
        nil ->
          %CatalogModel{}
          |> Ecto.Changeset.change(key: attrs.key)
          |> CatalogModel.remote_changeset(full)
          |> Repo.insert!()

          {inserted + 1, updated}

        %CatalogModel{fingerprint: ^fingerprint, status: "active"} ->
          {inserted, updated}

        %CatalogModel{} = row ->
          row
          |> CatalogModel.remote_changeset(full)
          |> Repo.update!()

          {inserted, updated + 1}
      end
    end)
  end

  # A model upstream no longer publishes is marked, never deleted: an operator's
  # `model_providers` row may be routing through it right now.
  defp mark_models_stale(models, now) do
    upstream = MapSet.new(models, & &1.key)

    gone =
      from(m in CatalogModel, where: m.status == "active")
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(upstream, &1.key))

    Enum.each(gone, fn row ->
      row
      |> CatalogModel.remote_changeset(%{status: "stale", fetched_at: now})
      |> Repo.update!()
    end)

    length(gone)
  end

  defp upsert_offers(offers, now) do
    existing =
      Repo.all(CatalogModelOffer)
      |> Map.new(&{{&1.provider_key, &1.model_key}, &1})

    Enum.reduce(offers, {0, 0}, fn attrs, {inserted, updated} ->
      fingerprint = CatalogModelOffer.fingerprint(attrs)

      full =
        Map.merge(attrs, %{fingerprint: fingerprint, fetched_at: now, status: "active"})

      case Map.get(existing, {attrs.provider_key, attrs.model_key}) do
        nil ->
          %CatalogModelOffer{}
          |> CatalogModelOffer.remote_changeset(full)
          |> Repo.insert!()

          {inserted + 1, updated}

        %CatalogModelOffer{fingerprint: ^fingerprint, status: "active"} ->
          {inserted, updated}

        %CatalogModelOffer{} = row ->
          row
          |> CatalogModelOffer.remote_changeset(full)
          |> Repo.update!()

          {inserted, updated + 1}
      end
    end)
  end

  defp mark_offers_stale(offers, now) do
    upstream = MapSet.new(offers, &{&1.provider_key, &1.model_key})

    gone =
      from(o in CatalogModelOffer, where: o.status == "active")
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(upstream, {&1.provider_key, &1.model_key}))

    Enum.each(gone, fn row ->
      row
      |> CatalogModelOffer.remote_changeset(%{status: "stale", fetched_at: now})
      |> Repo.update!()
    end)

    length(gone)
  end

  defp record(attrs) do
    CatalogSyncState.record(attrs)
  rescue
    e ->
      Logger.error("[catalog refresh] could not record state: #{Exception.message(e)}")
      :ok
  end

  # Keeps the maintenance page (and any other subscriber) in sync without a
  # reload: the refresh runs asynchronously, so the page needs to be told.
  defp broadcast do
    Phoenix.PubSub.broadcast(Tokengate.PubSub, @topic, {:catalog_refresh_done})
  end
end
