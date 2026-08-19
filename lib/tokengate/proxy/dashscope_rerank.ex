defmodule Tokengate.Proxy.DashScopeRerank do
  @moduledoc """
  Translates between TokenGate's Cohere rerank shape and DashScope's native
  rerank format.

  DashScope's native rerank endpoint (`text-rerank/text-rerank`) requires a
  NESTED request (`input.query` / `input.documents` / `parameters.*`) and
  wraps the response in `output.results`, reporting `usage.total_tokens`
  instead of `usage.prompt_tokens`.
  """

  @doc """
  Transforms a Cohere-format rerank request into DashScope's native format.

  Recognized Cohere top-level keys: `query`, `documents`, `top_n`,
  `return_documents`, `task`; `model` is forwarded as-is. Everything else
  is dropped — DashScope's rerank API only accepts `model`, `input` and
  `parameters`.
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
  Unwraps `output.results` into a top-level `results` list and maps
  `usage.total_tokens` to `usage.prompt_tokens` so the controller's cost
  estimator picks up the value.
  """
  @spec decode(map()) :: map()
  def decode(%{"output" => %{"results" => results}} = body) when is_list(results) do
    body
    |> Map.delete("output")
    |> Map.put("results", results)
    |> normalize_usage()
  end

  def decode(%{"output" => output} = body) when is_map(output) do
    body
  end

  def decode(body), do: body

  defp normalize_usage(%{"usage" => usage} = body) when is_map(usage) do
    case Map.get(usage, "total_tokens") do
      nil -> body
      total -> put_in(body, ["usage", "prompt_tokens"], total)
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
