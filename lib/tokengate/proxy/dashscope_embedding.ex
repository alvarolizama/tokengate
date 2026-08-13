defmodule Tokengate.Proxy.DashScopeEmbedding do
  @moduledoc """
  Translates between TokenGate's OpenAI embeddings shape and DashScope's
  native embeddings format.

  ## OpenAI (TokenGate lingua franca)

      request:  %{"model" => m, "input" => "text" | ["a", "b"], "dimensions" => n}
      response: %{"object" => "list", "data" => [%{"index" => 0, "embedding" => [...]}]}

  ## DashScope native

      request:  %{"model" => m, "input" => %{"texts" => ["a", "b"]}}
      response: %{"output" => %{"embeddings" => [%{"text_index" => 0, "embedding" => [...]}]},
                  "usage" => %{"total_tokens" => n}}
  """

  @doc """
  Translates an OpenAI embeddings request into DashScope's native format.
  A bare string input is wrapped into a one-element `texts` list.
  """
  @spec encode(map()) :: map()
  def encode(payload) do
    texts =
      case Map.get(payload, "input") do
        text when is_binary(text) -> [text]
        list when is_list(list) -> list
        _ -> []
      end

    base = %{
      "model" => Map.get(payload, "model"),
      "input" => %{"texts" => texts}
    }

    case Map.get(payload, "dimensions") do
      nil -> base
      dim when is_integer(dim) -> Map.put(base, "dimension", dim)
      _ -> base
    end
  end

  @doc """
  Translates a DashScope native embeddings response into the OpenAI shape.
  Maps `text_index` → `index` and `output.embeddings` → `data`, sorted by
  index so the caller sees the same order as the requested inputs.
  """
  @spec decode(map()) :: map()
  def decode(%{"output" => %{"embeddings" => embeddings}} = body) when is_list(embeddings) do
    data =
      embeddings
      |> Enum.map(fn e ->
        %{
          "index" => Map.get(e, "text_index", 0),
          "embedding" => Map.get(e, "embedding", []),
          "object" => "embedding"
        }
      end)
      |> Enum.sort_by(& &1["index"])

    %{
      "object" => "list",
      "data" => data,
      "model" => Map.get(body, "model"),
      "usage" => normalize_usage(body["usage"])
    }
  end

  def decode(body), do: body

  # DashScope reports `usage.total_tokens` but not `prompt_tokens`.
  defp normalize_usage(%{"total_tokens" => total} = usage) when is_integer(total) do
    Map.put(usage, "prompt_tokens", total)
  end

  defp normalize_usage(usage), do: usage
end
