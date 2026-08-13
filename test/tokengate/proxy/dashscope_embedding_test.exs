defmodule Tokengate.Proxy.DashScopeEmbeddingTest do
  @moduledoc "Unit tests for OpenAI ↔ DashScope embedding translation."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.DashScopeEmbedding

  describe "encode/1" do
    test "wraps a string input into texts" do
      encoded = DashScopeEmbedding.encode(%{"model" => "text-embedding-v4", "input" => "hola"})
      assert encoded["input"] == %{"texts" => ["hola"]}
    end

    test "passes a list input through as texts" do
      encoded = DashScopeEmbedding.encode(%{"model" => "m", "input" => ["a", "b"]})
      assert encoded["input"] == %{"texts" => ["a", "b"]}
    end

    test "maps dimensions to dimension" do
      encoded =
        DashScopeEmbedding.encode(%{"model" => "m", "input" => ["a"], "dimensions" => 256})

      assert encoded["dimension"] == 256
    end

    test "omits dimension when dimensions is absent" do
      encoded = DashScopeEmbedding.encode(%{"model" => "m", "input" => ["a"]})
      refute Map.has_key?(encoded, "dimension")
    end
  end

  describe "decode/1" do
    test "maps output.embeddings to data with text_index → index" do
      body = %{
        "output" => %{
          "embeddings" => [
            %{"text_index" => 1, "embedding" => [0.5, 0.6]},
            %{"text_index" => 0, "embedding" => [0.1, 0.2]}
          ]
        },
        "usage" => %{"total_tokens" => 12}
      }

      decoded = DashScopeEmbedding.decode(body)

      assert decoded["object"] == "list"
      assert decoded["data"] == [
               %{"index" => 0, "embedding" => [0.1, 0.2], "object" => "embedding"},
               %{"index" => 1, "embedding" => [0.5, 0.6], "object" => "embedding"}
             ]
      assert decoded["usage"] == %{"total_tokens" => 12, "prompt_tokens" => 12}
    end

    test "leaves non-output bodies untouched" do
      body = %{"error" => %{"message" => "boom"}}
      assert DashScopeEmbedding.decode(body) == body
    end
  end
end
