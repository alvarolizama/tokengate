defmodule Tokengate.Proxy.FormatTest do
  @moduledoc "Unit tests for the per-service format registry."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.Format

  describe "rerank_dialect_for/1" do
    test "returns :passthrough for cohere format" do
      assert Format.rerank_dialect_for(%{rerank_format: "cohere"}) == :passthrough
    end

    test "returns :passthrough for nil or missing format (default)" do
      assert Format.rerank_dialect_for(%{}) == :passthrough
      assert Format.rerank_dialect_for(nil) == :passthrough
    end

    test "returns encode/decode pair for dashscope format" do
      assert {encode, decode} = Format.rerank_dialect_for(%{rerank_format: "dashscope"})
      assert is_function(encode, 1)
      assert is_function(decode, 1)

      # encode is identity (flat request), decode unwraps output.results
      encoded = encode.(%{"query" => "q", "documents" => ["d"]})
      assert encoded["query"] == "q"

      decoded = decode.(%{"output" => %{"results" => []}})
      assert decoded["results"] == []
    end

    test "handles string-keyed maps" do
      assert Format.rerank_dialect_for(%{"rerank_format" => "dashscope"}) |> is_tuple()
    end
  end

  describe "embedding_dialect_for/1" do
    test "returns :passthrough for openai format" do
      assert Format.embedding_dialect_for(%{embedding_format: "openai"}) == :passthrough
    end

    test "returns :passthrough for nil or missing format (default)" do
      assert Format.embedding_dialect_for(%{}) == :passthrough
      assert Format.embedding_dialect_for(nil) == :passthrough
    end

    test "returns encode/decode pair for dashscope format" do
      assert {encode, decode} = Format.embedding_dialect_for(%{embedding_format: "dashscope"})
      assert is_function(encode, 1)
      assert is_function(decode, 1)
    end
  end
end
