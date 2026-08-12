defmodule Tokengate.Proxy.DashScopeRerankTest do
  @moduledoc "Unit tests for Cohere ↔ DashScope rerank translation."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.DashScopeRerank

  describe "encode/1" do
    test "wraps query and documents into input" do
      payload = %{
        "model" => "qwen3-rerank",
        "query" => "chaos",
        "documents" => ["doc cero", "doc uno"]
      }

      assert DashScopeRerank.encode(payload) == %{
               "model" => "qwen3-rerank",
               "input" => %{"query" => "chaos", "documents" => ["doc cero", "doc uno"]}
             }
    end

    test "moves top_n and return_documents into parameters" do
      payload = %{
        "model" => "qwen3-rerank",
        "query" => "q",
        "documents" => ["d"],
        "top_n" => 3,
        "return_documents" => true
      }

      encoded = DashScopeRerank.encode(payload)

      assert encoded["parameters"] == %{"top_n" => 3, "return_documents" => true}
      refute Map.has_key?(encoded, "query")
      refute Map.has_key?(encoded, "top_n")
    end

    test "omits parameters when no optional fields present" do
      encoded = DashScopeRerank.encode(%{"query" => "q", "documents" => ["d"]})
      refute Map.has_key?(encoded, "parameters")
    end

    test "preserves task when present" do
      encoded =
        DashScopeRerank.encode(%{
          "query" => "q",
          "documents" => ["d"],
          "task" => "qa"
        })

      assert encoded["parameters"] == %{"task" => "qa"}
    end
  end

  describe "decode/1" do
    test "unwraps output.results to top-level results" do
      body = %{
        "output" => %{
          "results" => [
            %{"index" => 1, "relevance_score" => 0.9, "document" => %{"text" => "doc uno"}},
            %{"index" => 0, "relevance_score" => 0.2, "document" => %{"text" => "doc cero"}}
          ]
        },
        "usage" => %{"total_tokens" => 42}
      }

      decoded = DashScopeRerank.decode(body)

      assert [
               %{"index" => 1, "relevance_score" => 0.9},
               %{"index" => 0, "relevance_score" => 0.2}
             ] =
               decoded["results"]

      refute Map.has_key?(decoded, "output")
      # DashScope total_tokens mapped to prompt_tokens for cost estimation
      assert decoded["usage"] == %{"prompt_tokens" => 42, "total_tokens" => 42}
    end

    test "leaves non-output bodies untouched" do
      body = %{"error" => %{"message" => "boom"}}
      assert DashScopeRerank.decode(body) == body
    end

    test "leaves output without results untouched" do
      body = %{"output" => %{"error" => "boom"}}
      assert DashScopeRerank.decode(body) == body
    end
  end
end
