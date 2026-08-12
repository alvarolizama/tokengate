defmodule Tokengate.Proxy.RerankDialectTest do
  @moduledoc "Unit tests for the rerank dialect registry."
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.RerankDialect

  describe "dialect_for/1" do
    test "returns :passthrough for cohere dialect" do
      assert RerankDialect.dialect_for(%{rerank_dialect: "cohere"}) == :passthrough
    end

    test "returns :passthrough for nil or missing dialect (default)" do
      assert RerankDialect.dialect_for(%{}) == :passthrough
      assert RerankDialect.dialect_for(nil) == :passthrough
    end

    test "returns encode/decode pair for dashscope dialect" do
      assert {encode, decode} = RerankDialect.dialect_for(%{rerank_dialect: "dashscope"})
      assert is_function(encode, 1)
      assert is_function(decode, 1)

      # Round-trip: encode a Cohere payload, decode a DashScope response
      encoded = encode.(%{"query" => "q", "documents" => ["d"]})
      assert encoded["input"]["query"] == "q"

      decoded = decode.(%{"output" => %{"results" => []}})
      assert decoded["results"] == []
    end

    test "handles string-keyed maps (decoded provider structs)" do
      assert RerankDialect.dialect_for(%{"rerank_dialect" => "dashscope"}) |> is_tuple()
    end
  end
end
