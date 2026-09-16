defmodule Mix.Tasks.Tokengate.Labs.Snapshot do
  @shortdoc "Downloads the models.dev lab catalog into priv/models_dev/labs.json"

  @moduledoc """
  Regenerates the vendored LAB snapshot from the models.dev API:

      mix tokengate.labs.snapshot
      mix tokengate.labs.snapshot --check
      mix tokengate.labs.snapshot --url https://mirror.example --dry-run

  models.dev publishes no lab endpoint, so the catalog is DERIVED from the two
  payloads it does publish: `/models.json` (canonical model ids — the lab is
  their prefix) and `/api.json` (provider names, used as lab display names).
  The derivation itself lives in `Tokengate.Providers.LabCatalog.derive/3`, the
  same code the runtime refresh uses, so the snapshot and a refresh cannot
  disagree.

  The file is read at compile time by `LabCatalog` (`@external_resource`), so a
  regeneration lands on the next compile.

  ## Options

    * `--url URL` (default `https://models.dev`) — origin to download from.
    * `--out PATH` (default `priv/models_dev/labs.json`).
    * `--dry-run` — print the result instead of writing it.
    * `--check` — compare the fresh derivation with the file on disk; exits
      non-zero on drift (0 = same, 1 = differs, 2 = fetch failed).
  """

  use Mix.Task

  alias Tokengate.Providers.LabCatalog

  @default_url "https://models.dev"
  @default_out "priv/models_dev/labs.json"
  @switches [url: :string, out: :string, dry_run: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    base_url = Keyword.get(opts, :url, @default_url)
    out_path = opts |> Keyword.get(:out, @default_out) |> Path.expand()

    Application.ensure_all_started(:req)

    case derive_from(base_url) do
      {:ok, entries} ->
        cond do
          Keyword.get(opts, :check, false) -> check(entries, out_path)
          Keyword.get(opts, :dry_run, false) -> print(entries, out_path, :dry_run)
          true -> write(entries, out_path)
        end

      {:error, reason} ->
        Mix.shell().error("no se pudo descargar el catálogo de labs: #{reason}")
        exit({:shutdown, 2})
    end
  end

  defp derive_from(base_url) do
    with {:ok, api} <- fetch(base_url <> "/api.json"),
         {:ok, models} <- fetch(base_url <> "/models.json") do
      {:ok, LabCatalog.derive(models, provider_names(api), logo_base_url: base_url)}
    end
  end

  defp fetch(url) do
    case Req.get(url,
           receive_timeout: 60_000,
           retry: false,
           headers: [{"user-agent", "tokengate-labs-snapshot"}]
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

  # Only the names are read from the provider payload: the lab display name is
  # the name of the provider with the same id.
  defp provider_names(api) do
    for {id, value} <- api,
        is_binary(id),
        is_map(value),
        name = value["name"],
        is_binary(name),
        name != "",
        into: %{},
        do: {id, name}
  end

  defp write(entries, out_path) do
    body = Jason.encode!(LabCatalog.encode_snapshot(entries), pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, body)
    print(entries, out_path, :written)
  end

  defp print(entries, out_path, mode) do
    label = if mode == :written, do: "escrito", else: "dry-run (nada escrito)"

    Mix.shell().info("#{length(entries)} labs (#{label}) → #{out_path}\n#{top(entries)}")
  end

  defp check(entries, out_path) do
    freshness = LabCatalog.encode_snapshot(entries)

    on_disk =
      case File.read(out_path) do
        {:ok, body} -> Jason.decode!(body)
        {:error, _} -> %{}
      end

    if on_disk == freshness do
      Mix.shell().info("sin cambios: #{out_path} ya refleja models.dev (#{length(entries)} labs)")
    else
      Mix.shell().error("el snapshot quedó atrás:\n#{describe_drift(on_disk, freshness)}")
      exit({:shutdown, 1})
    end
  end

  defp describe_drift(on_disk, freshness) do
    changed =
      freshness
      |> Enum.filter(fn {key, entry} -> Map.get(on_disk, key) != entry end)
      |> Enum.map(fn {key, entry} ->
        "  ~ #{key}: #{inspect(Map.get(on_disk, key))} → #{inspect(entry)}"
      end)

    [
      Enum.map(Map.keys(freshness) -- Map.keys(on_disk), &"  + #{&1}"),
      Enum.map(Map.keys(on_disk) -- Map.keys(freshness), &"  - #{&1}"),
      changed
    ]
    |> List.flatten()
    |> Enum.take(20)
    |> Enum.join("\n")
  end

  defp top(entries, count \\ 5) do
    entries
    |> Enum.sort_by(& &1.model_count, :desc)
    |> Enum.take(count)
    |> Enum.map_join("\n", fn entry ->
      "  #{String.pad_trailing(entry.key, 18)} #{String.pad_leading(to_string(entry.model_count), 3)} modelos  #{entry.name}"
    end)
  end
end
