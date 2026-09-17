defmodule Mix.Tasks.Tokengate.Models.Snapshot do
  @shortdoc "Downloads the models.dev model catalog into priv/models_dev/models_catalog.json"

  @moduledoc """
  Regenerates the vendored MODEL snapshot from the models.dev API:

      mix tokengate.models.snapshot
      mix tokengate.models.snapshot --check
      mix tokengate.models.snapshot --url https://mirror.example --dry-run

  models.dev publishes no model-level catalog on its own: the model dimension
  comes from `/models.json` (canonical models) and the provider × model offers
  from the per-provider `models` maps of `/api.json`. The derivation itself lives
  in `Tokengate.Providers.ModelCatalog.derive/3`, the same code the runtime
  refresh uses, so the snapshot and a refresh cannot disagree.

  The file is read at RUNTIME by `ModelCatalog.snapshot/0` (`CatalogSeed` uses it
  on a fresh database, and it is the offline fallback), so a regeneration does
  not need a recompile. It holds ~3000 models and ~6000 offers — ~2.7 MB of JSON,
  ~280 KB gzipped — so it is written GZIPPED as compact JSON on purpose: it is
  generated seed data, not something to review line by line. A `--out` ending
  anywhere else is written as plain JSON, which `ModelCatalog.snapshot_from/1`
  also accepts.

  ## Options

    * `--url URL` (default `https://models.dev`) — origin to download from.
    * `--out PATH` (default `priv/models_dev/models_catalog.json.gz`).
    * `--dry-run` — print the counts instead of writing the file.
    * `--check` — compare the fresh derivation with the file on disk; exits
      non-zero on drift (0 = same, 1 = differs, 2 = fetch failed).
  """

  use Mix.Task

  alias Tokengate.Providers.{Catalog, ModelCatalog}

  @default_url "https://models.dev"
  @default_out "priv/models_dev/models_catalog.json.gz"
  @switches [url: :string, out: :string, dry_run: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    base_url = Keyword.get(opts, :url, @default_url)
    out_path = opts |> Keyword.get(:out, @default_out) |> Path.expand()

    Application.ensure_all_started(:req)

    case derive_from(base_url) do
      {:ok, derived} ->
        cond do
          Keyword.get(opts, :check, false) -> check(derived, out_path)
          Keyword.get(opts, :dry_run, false) -> print(derived, out_path, :dry_run)
          true -> write(derived, out_path)
        end

      {:error, reason} ->
        Mix.shell().error("no se pudo descargar el catálogo de models: #{reason}")
        exit({:shutdown, 2})
    end
  end

  defp derive_from(base_url) do
    with {:ok, api} <- fetch(base_url <> "/api.json"),
         {:ok, models} <- fetch(base_url <> "/models.json") do
      entries = Catalog.normalize_providers(api)
      {:ok, ModelCatalog.derive(entries, api, models)}
    end
  end

  defp fetch(url) do
    case Req.get(url,
           receive_timeout: 120_000,
           retry: false,
           headers: [{"user-agent", "tokengate-models-snapshot"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, "#{url} no es JSON válido"}
        end

      {:ok, %{status: status}} ->
        {:error, "#{url} respondió #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp write(derived, out_path) do
    body = Jason.encode!(ModelCatalog.encode_snapshot(derived))
    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, encode(body, out_path))
    print(derived, out_path, :written)
  end

  # Gzipped by default (a 10x saving on generated data), plain for any other
  # extension so the file stays greppable when someone points `--out` at one.
  defp encode(body, out_path) do
    if Path.extname(out_path) == ".gz" do
      :zlib.gzip(body)
    else
      body <> "\n"
    end
  end

  defp print(derived, out_path, mode) do
    label = if mode == :written, do: "escrito", else: "dry-run (nada escrito)"

    Mix.shell().info(
      "#{length(derived.models)} modelos y #{length(derived.offers)} ofertas (#{label}) → #{out_path}"
    )
  end

  defp check(derived, out_path) do
    freshness = ModelCatalog.encode_snapshot(derived)

    on_disk =
      out_path
      |> ModelCatalog.snapshot_from()
      |> ModelCatalog.encode_snapshot()

    if on_disk == freshness do
      Mix.shell().info(
        "sin cambios: #{out_path} ya refleja models.dev (#{length(derived.models)} modelos, #{length(derived.offers)} ofertas)"
      )
    else
      Mix.shell().error("el snapshot quedó atrás:\n#{describe_drift(on_disk, freshness)}")
      exit({:shutdown, 1})
    end
  end

  defp describe_drift(on_disk, freshness) do
    on_models = Map.get(on_disk, "models") || %{}
    fresh_models = Map.get(freshness, "models") || %{}

    changed =
      fresh_models
      |> Enum.filter(fn {key, entry} -> Map.get(on_models, key) != entry end)
      |> Enum.take(20)
      |> Enum.map(fn {key, _entry} -> "  ~ #{key}" end)

    [
      Enum.map(Map.keys(fresh_models) -- Map.keys(on_models), &"  + #{&1}"),
      Enum.map(Map.keys(on_models) -- Map.keys(fresh_models), &"  - #{&1}"),
      changed
    ]
    |> List.flatten()
    |> Enum.take(20)
    |> Enum.join("\n")
  end
end
