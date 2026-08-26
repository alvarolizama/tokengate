defmodule Tokengate.Proxy.RuninfraRerankTest do
  @moduledoc "Unit tests for Cohere ↔ RunInfra rerank translation."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.RuninfraRerank

  describe "encode/1" do
    test "renames documents to texts" do
      payload = %{
        "model" => "qwen3-reranker-8b",
        "query" => "Which document is most relevant?",
        "documents" => ["doc cero", "doc uno"]
      }

      encoded = RuninfraRerank.encode(payload)

      assert encoded["texts"] == ["doc cero", "doc uno"]
      refute Map.has_key?(encoded, "documents")
      assert encoded["query"] == "Which document is most relevant?"
      assert encoded["model"] == "qwen3-reranker-8b"
    end

    test "handles empty documents list" do
      encoded = RuninfraRerank.encode(%{"query" => "q", "documents" => []})
      assert encoded["texts"] == []
      refute Map.has_key?(encoded, "documents")
    end

    test "preserves optional top_n and return_documents" do
      encoded =
        RuninfraRerank.encode(%{
          "query" => "q",
          "documents" => ["d"],
          "top_n" => 3,
          "return_documents" => true
        })

      assert encoded["top_n"] == 3
      assert encoded["return_documents"] == true
    end

    test "handles missing documents gracefully" do
      encoded = RuninfraRerank.encode(%{"query" => "q"})
      assert encoded["texts"] == []
      refute Map.has_key?(encoded, "documents")
    end
  end

  describe "decode/1" do
    test "passes through Cohere-style results unchanged" do
      body = %{
        "results" => [
          %{"index" => 0, "relevance_score" => 0.95},
          %{"index" => 1, "relevance_score" => 0.12}
        ],
        "usage" => %{"prompt_tokens" => 100}
      }

      assert RuninfraRerank.decode(body) == body
    end

    test "passes through error bodies unchanged" do
      body = %{"error" => %{"message" => "boom"}}
      assert RuninfraRerank.decode(body) == body
    end

    test "passes through empty body unchanged" do
      assert RuninfraRerank.decode(%{}) == %{}
    end
  end
end
