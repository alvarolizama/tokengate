defmodule Tokengate.Proxy.UsageNormalizerTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.UsageNormalizer

  describe "normalize/2 openai" do
    test "normalizes a full response" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{"cached_tokens" => 20}
        }
      }

      # Cache tokens saved for observability, NOT subtracted from prompt_tokens.
      assert UsageNormalizer.normalize(:openai, body) == %{
               prompt_tokens: 100,
               completion_tokens: 50,
               cache_read_tokens: 20,
               cache_creation_tokens: 0
             }
    end

    test "missing details default to zero" do
      body = %{"usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}}

      assert UsageNormalizer.normalize(:openai, body) == %{
               prompt_tokens: 10,
               completion_tokens: 5,
               cache_read_tokens: 0,
               cache_creation_tokens: 0
             }
    end

    test "no usage returns nil" do
      assert UsageNormalizer.normalize(:openai, %{"choices" => []}) == nil
    end
  end

  describe "from_openai_stream_chunk/1" do
    test "extracts usage from final chunk" do
      chunk = %{"usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3}}

      assert UsageNormalizer.from_openai_stream_chunk(chunk) == %{
               prompt_tokens: 7,
               completion_tokens: 3,
               cache_read_tokens: 0,
               cache_creation_tokens: 0
             }
    end

    test "regular chunks have no usage" do
      assert UsageNormalizer.from_openai_stream_chunk(%{"choices" => [%{"delta" => %{}}]}) == nil
    end
  end
end
