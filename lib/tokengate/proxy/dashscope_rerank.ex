defmodule Tokengate.Proxy.DashScopeRerank do
  @moduledoc """
  Translates DashScope's native rerank RESPONSE back to TokenGate's Cohere
  shape.

  DashScope's rerank request is identical to Cohere's (flat `query` /
  `documents` / `top_n` / `return_documents`), so only the response needs
  translation: DashScope wraps results in `output.results` and reports
  `usage.total_tokens` instead of `usage.prompt_tokens`.
  """

  @doc "Identity — the DashScope rerank request is already Cohere-shaped."
  @spec encode(map()) :: map()
  def encode(payload), do: payload

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

  def decode(body), do: body

  defp normalize_usage(%{"usage" => usage} = body) when is_map(usage) do
    case Map.get(usage, "total_tokens") do
      nil -> body
      total -> put_in(body, ["usage", "prompt_tokens"], total)
    end
  end

  defp normalize_usage(body), do: body
end
