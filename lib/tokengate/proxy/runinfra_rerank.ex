defmodule Tokengate.Proxy.RuninfraRerank do
  @moduledoc """
  Translates between TokenGate's Cohere rerank shape and RunInfra's native
  rerank format.

  RunInfra's rerank endpoint (`/v1/rerank`) accepts `texts` instead of
  `documents` and returns Cohere-style `results` with `relevance_score`
  (sigmoid 0–1), so only the request side needs translation — the response
  is already in the shape TokenGate expects.

  ## Cohere (TokenGate lingua franca)

      request:  %{"model" => m, "query" => q, "documents" => [...], "top_n" => n}
      response: %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]}

  ## RunInfra native

      request:  %{"model" => m, "query" => q, "texts" => [...]}
      response: %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]}
  """

  @doc """
  Translates a Cohere-format rerank request into RunInfra's native format.
  Renames `documents` → `texts`. All other recognized Cohere fields
  (`query`, `top_n`, `return_documents`, `task`) are forwarded as-is —
  RunInfra accepts them at the top level.
  """
  @spec encode(map()) :: map()
  def encode(payload) do
    payload
    |> Map.delete("documents")
    |> Map.put("texts", Map.get(payload, "documents", []))
  end

  @doc """
  RunInfra already returns Cohere-style `results`, so the response is
  passed through untouched. The controller's `normalize_rerank_body/1`
  handles any provider that wraps results differently.
  """
  @spec decode(map()) :: map()
  def decode(body), do: body
end
