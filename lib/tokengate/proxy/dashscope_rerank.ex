defmodule Tokengate.Proxy.DashScopeRerank do
  @moduledoc """
  Translates between TokenGate's Cohere rerank shape and DashScope's native
  rerank format.

  ## DashScope native format

  Request:

      %{
        "model" => "qwen3-rerank",
        "input" => %{"query" => "...", "documents" => ["..."]},
        "parameters" => %{"top_n" => 5, "return_documents" => true}
      }

  Response:

      %{
        "output" => %{
          "results" => [
            %{"index" => 0, "relevance_score" => 0.93, "document" => %{"text" => "..."}}
          ]
        }
      }

  TokenGate's Cohere shape (what the proxy controller expects):

  Request:

      %{
        "model" => "qwen3-rerank",
        "query" => "...",
        "documents" => ["..."],
        "top_n" => 5,
        "return_documents" => true
      }

  Response:

      %{
        "results" => [
          %{"index" => 0, "relevance_score" => 0.93, "document" => %{"text" => "..."}}
        ]
      }
  """

  @doc """
  Transforms a Cohere-format rerank request into DashScope's native format.

  Recognized Cohere top-level keys: `query`, `documents`, `top_n`,
  `return_documents`, `task`. Everything else is dropped — DashScope's
  rerank API only accepts `model`, `input` and `parameters`.
  """
  @spec encode(map()) :: map()
  def encode(payload) do
    input = %{
      "query" => Map.fetch!(payload, "query"),
      "documents" => Map.fetch!(payload, "documents")
    }

    parameters =
      %{}
      |> maybe_put(payload, "top_n")
      |> maybe_put(payload, "return_documents")
      |> maybe_put(payload, "task")

    base = %{
      "model" => Map.get(payload, "model"),
      "input" => input
    }

    if parameters == %{} do
      base
    else
      Map.put(base, "parameters", parameters)
    end
  end

  @doc """
  Transforms DashScope's native rerank response into the Cohere shape.

  Unwraps `output.results` into a top-level `results` list. Each result's
  `document` (a map with `text`) is passed through unchanged — it matches
  the Cohere contract already. When the response lacks the expected shape,
  it is returned untouched so the caller can surface the upstream error.
  """
  @spec decode(map()) :: map()
  def decode(%{"output" => %{"results" => results}} = body) when is_list(results) do
    body
    |> Map.delete("output")
    |> Map.put("results", results)
    |> normalize_usage()
  end

  def decode(%{"output" => output} = body) when is_map(output) do
    # Non-list results (e.g. an error envelope inside output): keep the body
    # intact, the controller will surface whatever upstream said.
    body
  end

  def decode(body), do: body

  # DashScope reports `usage.total_tokens` but not `prompt_tokens`. Map
  # total_tokens to prompt_tokens so the controller's cost estimator picks
  # up the value instead of defaulting to 0.
  defp normalize_usage(%{"usage" => usage} = body) when is_map(usage) do
    case Map.get(usage, "total_tokens") do
      nil ->
        body

      total ->
        put_in(body, ["usage", "prompt_tokens"], total)
    end
  end

  defp normalize_usage(body), do: body

  defp maybe_put(acc, payload, key) do
    case Map.get(payload, key) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end
end
