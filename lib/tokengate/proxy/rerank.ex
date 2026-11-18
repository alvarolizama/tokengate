defmodule Tokengate.Proxy.Rerank do
  @moduledoc """
  The rerank surface: one public contract, five upstream wires.

  `post/4` is the adapter_fun behind `POST /v1/rerank`. The canonical request
  is `{model, query, documents, top_n}` and the canonical response is a
  `results[]` array of `{index, relevance_score}` — nothing else. Every
  upstream that serves rerank is reached through that ONE contract:

      upstream      request wire                       response wire
      ------------  --------------------------------   ---------------------------
      Fireworks     canonical + `return_documents`     `data[]` + `usage`
      OpenRouter    canonical                          `results[]`
      NaN           canonical                          `results[]`
      Helmcode      canonical                          `results[]` + `meta.billed_units`
      oMLX (local)  canonical                          `results[]`

  ## Why this module and not a ProviderAdapter dialect

  The surface has ONE input shape for every provider and ONE client contract;
  the only thing that varies is the endpoint (which `ProviderPaths` owns) and
  two request/response details (which `Catalog.rerank_shape/1` names). That is
  the `Proxy.Decisions` mould — a module above the transport — not an
  `@dialects` entry in `ProviderAdapter` (F67): a dialect is what an upstream
  speaks for CHAT, and this surface is not chat with a different path.

  Error classification stays in `ProviderAdapter` through `OpenAIAdapter`, so
  a rerank attempt takes part in the same fallback matrix, breaker and budget
  as every other service.

  ## The canonical documents

  `documents` is a non-empty array. Each entry is:

    * a string — the document text; or
    * an object with a `text` string — structured input, where the caller may
      carry any other fields (its own `metadata`). The gateway forwards the
      TEXT only: no upstream wire of the five documents a metadata envelope,
      so inventing one would be sending a field nobody reads. The caller keeps
      its metadata on its side; `index` in the response is the position in the
      array it sent, so it always maps back.

  ## The canonical response

      %{"results" => [%{"index" => 2, "relevance_score" => 0.98}, …]}

  plus `"usage"` when the upstream reported billable counters (Fireworks
  `usage`, Helmcode `meta.billed_units`), and `"cost"` when it reported one
  (`usage.cost` — `UsageNormalizer` reads it and the reported cost wins over
  any manual price). The upstream's own extras — Fireworks' echoed `document`
  and `object: "list"`, the `meta` block — are dropped: the client contract is
  canonical, not vendor-shaped.

  A 2xx that carries neither list is NOT turned into an empty ranking (that
  would say "nothing is relevant" when the truth is "we cannot read this
  answer"): it is a gateway error with its own code.
  """

  alias Tokengate.Proxy.{OpenAIAdapter, RawResponse}
  alias Tokengate.Providers.Catalog

  @missing_model_message "the lane has no upstream model id configured: " <>
                           "set one on the model's provider row before routing rerank requests"

  @non_json_message "rerank upstream answered a non-JSON body"

  @unreadable_message "rerank upstream answered a body without a results[] or data[] list"

  # Keys an upstream may use for the input-only token counters of a rerank
  # call. Rerank never bills output tokens, so a `total` is the same number.
  @usage_token_keys ~w(prompt_tokens input_tokens tokens total_tokens billed_tokens)

  @doc """
  Validates the canonical request before any gate or credential is touched.

  A malformed body is the caller's fault: rejecting it here spends no
  credential slot, no budget hold and no upstream call. `model` is validated by
  the controller's own `require_model/1` (same error every endpoint gives).
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(payload) when is_map(payload) do
    with :ok <- validate_query(payload["query"]),
         {:ok, _documents} <- canonical_documents(payload["documents"]),
         :ok <- validate_top_n(payload["top_n"]) do
      :ok
    end
  end

  def validate(_payload), do: {:error, "the request body must be a JSON object"}

  @doc """
  The text of every canonical document, in order (invalid entries are skipped).

  Used by the cost path to estimate input tokens when the upstream reported no
  usage — the same honest estimate the embeddings surface uses.
  """
  @spec document_texts(term()) :: [String.t()]
  def document_texts(documents) do
    documents
    |> List.wrap()
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
  end

  @doc """
  POSTs one canonical rerank request upstream and normalizes the answer.

  Same result tuples as `OpenAIAdapter.service_post/5`:

    * `{:ok, canonical_body, latency_ms, resp_headers}`
    * `{:error, reason, status | nil, error_message | nil}`

  A lane with no `provider_model` cannot be sent anywhere (its wire would carry
  `model: null` and the upstream would answer its own 400, blaming the caller
  for a gateway misconfiguration), so it fails locally with `:lane_not_servable`
  — the controller excludes the lane and moves on, and the client, when no lane
  is left, gets the gateway's own code.
  """
  @spec post(map(), map(), map(), keyword()) ::
          {:ok, map(), non_neg_integer(), [{String.t(), String.t()}]}
          | {:error, atom(), non_neg_integer() | nil, String.t() | nil}
  def post(provider, credential, payload, opts) do
    with {:ok, model} <- upstream_model(payload),
         {:ok, documents} <- canonical_documents(payload["documents"]) do
      body = upstream_body(provider, model, payload, documents)

      case OpenAIAdapter.service_post(provider, credential, :rerank, body, opts) do
        {:ok, %RawResponse{} = raw, _latency, _headers} ->
          {:error, :server_error, 502, @non_json_message <> " (#{raw.content_type})"}

        {:ok, answer, latency, headers} ->
          case normalize(answer) do
            {:ok, canonical} -> {:ok, canonical, latency, headers}
            {:error, message} -> {:error, :server_error, 502, message}
          end

        {:error, reason, status, message} ->
          {:error, reason, status, message}
      end
    else
      {:error, :lane_not_servable} -> {:error, :lane_not_servable, nil, @missing_model_message}
      {:error, message} when is_binary(message) -> {:error, :bad_request, 400, message}
    end
  end

  @doc """
  Normalizes one upstream rerank answer to the canonical response.

  Absorbs BOTH list shapes by presence — `data[]` (Fireworks) and `results[]`
  (OpenRouter, NaN, Helmcode, oMLX) — because the response is the side a
  mislabeled provider must not be able to break: `rerank_shape/1` decides the
  REQUEST, presence decides the response.
  """
  @spec normalize(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize(%{"results" => results} = answer) when is_list(results) do
    canonical(answer, results)
  end

  def normalize(%{"data" => data} = answer) when is_list(data) do
    canonical(answer, data)
  end

  def normalize(%RawResponse{}), do: {:error, @non_json_message}

  def normalize(_answer), do: {:error, @unreadable_message}

  @doc """
  The wire a provider speaks (`Catalog.rerank_shape/1`, default `:results`).
  """
  @spec shape(map() | nil) :: :results | :fireworks
  def shape(provider) do
    key = Map.get(provider || %{}, :key) || Map.get(provider || %{}, "key")
    Catalog.rerank_shape(key)
  end

  ## Request ###################################################################

  # The upstream id of the lane. `execute_simple` rewrites the payload's model
  # before calling this module, so a missing value means a lane row with no
  # `provider_model` — a gateway-side gap, not a caller error.
  defp upstream_model(%{"model" => model}) when is_binary(model) do
    case String.trim(model) do
      "" -> {:error, :lane_not_servable}
      trimmed -> {:ok, trimmed}
    end
  end

  defp upstream_model(_payload), do: {:error, :lane_not_servable}

  defp upstream_body(provider, model, payload, documents) do
    body = %{
      "model" => model,
      "query" => String.trim(payload["query"]),
      "documents" => documents
    }

    body =
      case top_n(payload["top_n"]) do
        nil -> body
        n -> Map.put(body, "top_n", n)
      end

    case shape(provider) do
      # Fireworks echoes every document by default (`return_documents: true`),
      # which doubles the body for a ranking the canonical contract already
      # carries as indexes. The field is documented in its API, so it is the
      # one request knob this module adds; the Cohere-envelope resellers get
      # exactly the canonical body.
      :fireworks -> Map.put(body, "return_documents", false)
      :results -> body
    end
  end

  defp canonical_documents(documents) when is_list(documents) and documents != [] do
    documents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case canonical_document(entry) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, {:error, document_error(index)}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      {:error, message} -> {:error, message}
    end
  end

  defp canonical_documents(nil), do: {:error, "documents is required (a non-empty array)"}

  defp canonical_documents([]), do: {:error, "documents is required (a non-empty array)"}

  defp canonical_documents(_documents), do: {:error, "documents must be an array"}

  defp canonical_document(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp canonical_document(%{"text" => text}) when is_binary(text), do: canonical_document(text)

  defp canonical_document(_entry), do: :error

  defp document_error(index) do
    "documents[#{index}] must be a non-empty string or an object with a non-empty " <>
      "\"text\" field"
  end

  defp validate_query(query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, "query is required (a non-empty string)"}
      _ -> :ok
    end
  end

  defp validate_query(_query), do: {:error, "query is required (a non-empty string)"}

  defp validate_top_n(nil), do: :ok

  defp validate_top_n(n) when is_integer(n) and n > 0, do: :ok

  # JSON numbers arrive as floats when the client writes `5.0`: a whole
  # positive float is still a valid count (same rule as the image surface's
  # `n`).
  defp validate_top_n(n) when is_float(n) and n > 0 and n == trunc(n), do: :ok

  defp validate_top_n(n) do
    {:error, "top_n must be a positive integer (got: #{inspect(n)})"}
  end

  # Upstream `top_n`: an integer on the wire, never `5.0`.
  defp top_n(n) when is_integer(n) and n > 0, do: n
  defp top_n(n) when is_float(n) and n > 0 and n == trunc(n), do: trunc(n)
  defp top_n(_n), do: nil

  ## Response ##################################################################

  defp canonical(answer, results) do
    canonical_results = results |> Enum.map(&canonical_result/1) |> Enum.reject(&is_nil/1)

    cond do
      canonical_results == [] and results != [] ->
        {:error, @unreadable_message}

      true ->
        response = %{"results" => canonical_results}

        response
        |> maybe_put("usage", usage(answer))
        |> maybe_put("cost", reported_cost(answer))
        |> then(&{:ok, &1})
    end
  end

  defp canonical_result(%{} = result) do
    with index when is_integer(index) <- integer(result["index"]),
         score when is_number(score) <- number(result["relevance_score"]) do
      %{"index" => index, "relevance_score" => score}
    else
      _ -> nil
    end
  end

  defp canonical_result(_result), do: nil

  # The billable counters of the answer, in the canonical usage shape. Two
  # documented sources (F59/F60):
  #
  #   * Fireworks — `usage: {prompt_tokens, total_tokens}`;
  #   * Helmcode — its own `meta.billed_units` block, whose inner key names the
  #     public docs do not enumerate. Read conservatively: the first known
  #     counter wins and an unrecognizable block means "no usage reported"
  #     (the lane's `per_request` price is the honest fallback for the flat
  #     rate), never a guessed number.
  defp usage(answer) do
    answer
    |> usage_source()
    |> case do
      nil -> nil
      counters -> canonical_usage(counters)
    end
  end

  defp usage_source(%{"usage" => %{} = usage}), do: usage
  defp usage_source(%{"meta" => %{"billed_units" => %{} = units}}), do: units
  defp usage_source(%{"meta" => %{"billed_units" => units}}) when is_number(units), do: units
  defp usage_source(_answer), do: nil

  defp canonical_usage(units) when is_number(units) and units >= 0 do
    %{"prompt_tokens" => trunc(units), "completion_tokens" => 0, "total_tokens" => trunc(units)}
  end

  defp canonical_usage(%{} = units) do
    cost = reported_cost(units)

    case token_counter(units) do
      nil ->
        # A reported cost with no readable counters still travels: the reported
        # cost wins over any manual price, and the controller's estimator fills
        # the token counts from the request.
        if cost, do: %{"cost" => cost}

      tokens ->
        %{
          "prompt_tokens" => tokens,
          "completion_tokens" => 0,
          "total_tokens" => tokens
        }
        |> maybe_put("cost", cost)
    end
  end

  defp canonical_usage(_units), do: nil

  defp token_counter(units) do
    Enum.find_value(@usage_token_keys, fn key ->
      case number(units[key]) do
        n when is_number(n) and n >= 0 -> trunc(n)
        _ -> nil
      end
    end)
  end

  defp reported_cost(%{"cost" => cost}) when is_number(cost) or is_binary(cost), do: cost
  defp reported_cost(_answer), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp integer(_value), do: nil

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
