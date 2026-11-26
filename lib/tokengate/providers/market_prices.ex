defmodule Tokengate.Providers.MarketPrices do
  @moduledoc """
  Lightweight, display-only market reference pricing extracted from
  `models.dev/api.json`.

  Unlike the retired `catalog_models` / `catalog_model_offers` mirror, this
  module stores ZERO mirror tables in Postgres. Instead:

    * `extract_index/1` parses the `models` cost blocks out of the `api.json`
      payload `CatalogRefreshWorker` already downloads and caches a compact
      in-memory lookup table via `:persistent_term`.
    * `sync_configured_models/2` updates ONLY the `models` rows that actually
      exist in TokenGate (never overwriting `market_price_source == "manual"`).
    * `fetch_and_lookup/1` lets `/catalog/models` look up an individual model on
      demand (fetching `CatalogRefreshWorker.url/0` once if the index hasn't
      been populated since boot).

  These prices are **strictly informational** — `CostCalculator`, billing, and
  consumption counters NEVER read `models.market_*`.
  """

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{CatalogRefreshWorker, Model, ModelIds}
  alias Tokengate.Repo

  @pt_key {__MODULE__, :index}

  @type price_entry :: %{
          provider_key: String.t(),
          model_id: String.t(),
          input: Decimal.t() | nil,
          output: Decimal.t() | nil,
          cache: Decimal.t() | nil,
          context_window: pos_integer() | nil
        }

  @type index :: %{
          by_pair: %{{String.t(), String.t()} => price_entry()},
          by_id: %{String.t() => [price_entry()]},
          by_short: %{String.t() => [price_entry()]}
        }

  @doc "Extracts a compact market-price lookup index from a decoded `models.dev/api.json` map."
  @spec extract_index(map() | any()) :: index()
  def extract_index(payload) when is_map(payload) do
    entries =
      Enum.flat_map(payload, fn
        {provider_key, %{"models" => models}} when is_binary(provider_key) and is_map(models) ->
          extract_provider_models(provider_key, models)

        _ ->
          []
      end)

    %{
      by_pair: Map.new(entries, fn e -> {{e.provider_key, String.downcase(e.model_id)}, e} end),
      by_id: Enum.group_by(entries, &String.downcase(&1.model_id)),
      by_short: Enum.group_by(entries, &String.downcase(ModelIds.short_name(&1.model_id)))
    }
  end

  def extract_index(_), do: %{by_pair: %{}, by_id: %{}, by_short: %{}}

  defp extract_provider_models(provider_key, models) do
    Enum.flat_map(models, fn
      {model_id, %{} = model_meta} when is_binary(model_id) ->
        cost = if is_map(model_meta["cost"]), do: model_meta["cost"], else: %{}
        input = to_decimal(cost["input"])
        output = to_decimal(cost["output"])
        cache = to_decimal(cost["cache_read"])
        context_window = to_pos_int(get_in(model_meta, ["limit", "context"]))

        if is_nil(input) and is_nil(output) and is_nil(cache) and is_nil(context_window) do
          []
        else
          [
            %{
              provider_key: provider_key,
              model_id: model_id,
              input: input,
              output: output,
              cache: cache,
              context_window: context_window
            }
          ]
        end

      _ ->
        []
    end)
  end

  @doc "Caches the extracted market-price index in `:persistent_term`."
  @spec put_index(index()) :: :ok
  def put_index(%{by_pair: _, by_id: _, by_short: _} = index) do
    :persistent_term.put(@pt_key, index)
    :ok
  end

  @doc "Returns the cached market-price index, or `nil` if none has been loaded yet."
  @spec get_index() :: index() | nil
  def get_index, do: :persistent_term.get(@pt_key, nil)

  @doc "Clears the cached index (intended for tests)."
  @spec clear_index() :: boolean()
  def clear_index, do: :persistent_term.erase(@pt_key)

  @doc """
  Looks up an informational market price entry in `index`.

  Options:
    * `:name` — model name in TokenGate (e.g. `"gpt-4o"`, `"claude-sonnet-4-5"`)
    * `:lab_key` — optional lab slug (e.g. `"openai"`, `"anthropic"`)
    * `:lanes` — optional list of `{provider_key, provider_model}` tuples
  """
  @spec lookup(index(), keyword()) :: {:ok, price_entry()} | :not_found
  def lookup(%{by_pair: by_pair, by_id: by_id, by_short: by_short}, opts) do
    name = opts |> Keyword.get(:name) |> normalize_str()
    lab_key = opts |> Keyword.get(:lab_key) |> normalize_str()
    lanes = Keyword.get(opts, :lanes, [])

    with nil <- match_lanes(by_pair, lanes),
         nil <- match_lab(by_pair, lab_key, name),
         nil <- match_candidates(by_id, [name], lab_key, lanes),
         nil <- match_candidates(by_short, short_candidates(name), lab_key, lanes) do
      :not_found
    else
      entry -> {:ok, entry}
    end
  end

  def lookup(_, _), do: :not_found

  @doc """
  Looks up market pricing for an individual model, using the cached index or
  downloading `CatalogRefreshWorker.url/0` once if empty.
  """
  @spec fetch_and_lookup(keyword()) :: {:ok, price_entry()} | :not_found | {:error, term()}
  def fetch_and_lookup(opts) do
    case ensure_index() do
      {:ok, index} -> lookup(index, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_index do
    case get_index() do
      %{by_pair: _} = index ->
        {:ok, index}

      nil ->
        case fetch_catalog_payload() do
          {:ok, payload} ->
            index = extract_index(payload)
            put_index(index)
            {:ok, index}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_catalog_payload do
    url = CatalogRefreshWorker.url()

    case Req.get(url,
           receive_timeout: 20_000,
           retry: false,
           headers: [{"user-agent", "tokengate-market-prices"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts prices from a decoded `api.json` payload, updates `:persistent_term`,
  and refreshes `market_*` columns on configured `models` rows (skipping rows
  whose `market_price_source == "manual"`).
  """
  @spec sync_configured_models(map(), DateTime.t() | nil) :: %{updated: non_neg_integer()}
  def sync_configured_models(payload, now \\ nil)

  def sync_configured_models(payload, now) when is_map(payload) do
    index = extract_index(payload)
    put_index(index)

    if map_size(index.by_pair) == 0 do
      %{updated: 0}
    else
      sync_now = (now || DateTime.utc_now()) |> DateTime.truncate(:second)

      models =
        from(m in Model,
          where: is_nil(m.market_price_source) or m.market_price_source != "manual",
          preload: [model_providers: [credential: :provider, pool: :provider]]
        )
        |> Repo.all()

      updated =
        Enum.reduce(models, 0, fn model, acc ->
          lanes = model_lanes_for_lookup(model)

          case lookup(index, name: model.name, lab_key: model.lab_key, lanes: lanes) do
            {:ok, %{input: nil, output: nil, cache: nil}} ->
              acc

            {:ok, entry} ->
              attrs = %{
                market_input_price_per_1m: entry.input,
                market_output_price_per_1m: entry.output,
                market_cache_price_per_1m: entry.cache,
                market_price_source: "models.dev",
                market_price_synced_at: sync_now
              }

              if changed_market_prices?(model, attrs) do
                case model |> Model.changeset(attrs) |> Repo.update() do
                  {:ok, _} -> acc + 1
                  {:error, _} -> acc
                end
              else
                acc
              end

            :not_found ->
              acc
          end
        end)

      %{updated: updated}
    end
  end

  def sync_configured_models(_, _), do: %{updated: 0}

  defp model_lanes_for_lookup(%Model{model_providers: lanes}) when is_list(lanes) do
    Enum.flat_map(lanes, fn lane ->
      provider_key =
        cond do
          lane.credential && lane.credential.provider -> lane.credential.provider.key
          lane.pool && lane.pool.provider -> lane.pool.provider.key
          true -> nil
        end

      if is_binary(provider_key) and is_binary(lane.provider_model) do
        [{provider_key, lane.provider_model}]
      else
        []
      end
    end)
  end

  defp model_lanes_for_lookup(_), do: []

  defp changed_market_prices?(model, attrs) do
    not decimal_eq?(model.market_input_price_per_1m, attrs.market_input_price_per_1m) or
      not decimal_eq?(model.market_output_price_per_1m, attrs.market_output_price_per_1m) or
      not decimal_eq?(model.market_cache_price_per_1m, attrs.market_cache_price_per_1m) or
      model.market_price_source != "models.dev"
  end

  defp decimal_eq?(nil, nil), do: true
  defp decimal_eq?(nil, _), do: false
  defp decimal_eq?(_, nil), do: false
  defp decimal_eq?(a, b), do: Decimal.equal?(a, b)

  defp match_lanes(_by_pair, []), do: nil

  defp match_lanes(by_pair, lanes) do
    Enum.find_value(lanes, fn
      {provider_key, pm} when is_binary(provider_key) and is_binary(pm) ->
        down = String.downcase(String.trim(pm))
        short = String.downcase(ModelIds.short_name(pm))
        Map.get(by_pair, {provider_key, down}) || Map.get(by_pair, {provider_key, short})

      _ ->
        nil
    end)
  end

  defp match_lab(_by_pair, nil, _name), do: nil
  defp match_lab(_by_pair, _lab_key, nil), do: nil

  defp match_lab(by_pair, lab_key, name) do
    down = String.downcase(name)
    short = String.downcase(ModelIds.short_name(name))

    Map.get(by_pair, {lab_key, down}) ||
      Map.get(by_pair, {lab_key, "#{lab_key}/#{down}"}) ||
      Map.get(by_pair, {lab_key, short}) ||
      Map.get(by_pair, {lab_key, "#{lab_key}/#{short}"})
  end

  defp match_candidates(index_map, candidates, lab_key, lanes) do
    lane_providers = MapSet.new(lanes, &elem(&1, 0))

    candidates
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn cand ->
      case Map.get(index_map, String.downcase(cand)) do
        nil -> nil
        [] -> nil
        entries -> pick_best_entry(entries, lab_key, lane_providers)
      end
    end)
  end

  defp pick_best_entry(entries, lab_key, lane_providers) do
    Enum.min_by(entries, fn e ->
      {
        if(lab_key && e.provider_key == lab_key, do: 0, else: 1),
        if(MapSet.member?(lane_providers, e.provider_key), do: 0, else: 1),
        if(e.input && e.output, do: 0, else: 1),
        e.provider_key,
        e.model_id
      }
    end)
  end

  defp short_candidates(nil), do: []

  defp short_candidates(name) do
    [name, ModelIds.short_name(name)] |> Enum.uniq()
  end

  defp normalize_str(nil), do: nil

  defp normalize_str(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_str(_), do: nil

  defp to_decimal(v) when is_integer(v) and v >= 0, do: Decimal.new(v)

  defp to_decimal(v) when is_float(v) and v >= 0.0 do
    v |> Decimal.from_float() |> Decimal.round(6)
  end

  defp to_decimal(v) when is_binary(v) do
    case Decimal.parse(String.trim(v)) do
      {d, ""} -> if Decimal.compare(d, 0) != :lt, do: Decimal.round(d, 6), else: nil
      _ -> nil
    end
  end

  defp to_decimal(_), do: nil

  defp to_pos_int(v) when is_integer(v) and v > 0, do: v
  defp to_pos_int(_), do: nil
end
