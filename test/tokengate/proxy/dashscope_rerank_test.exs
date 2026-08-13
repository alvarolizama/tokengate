defmodule Tokengate.Proxy.DashScopeRerankTest do
  @moduledoc "Unit tests for DashScope rerank response translation."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.DashScopeRerank

  describe "encode/1" do
    test "is identity — the DashScope rerank request is already Cohere-shaped" do
      payload = %{
        "model" => "qwen3-rerank",
        "query" => "chaos",
        "documents" => ["doc cero", "doc uno"],
        "top_n" => 3,
        "return_documents" => true
      }

      assert DashScopeRerank.encode(payload) == payload
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
             ] = decoded["results"]

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
