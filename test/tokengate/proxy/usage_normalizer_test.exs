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

    test "extracts cache_write_tokens (OpenRouter) into cache_creation_tokens" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 1000,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{
            "cached_tokens" => 800,
            "cache_write_tokens" => 120
          }
        }
      }

      assert UsageNormalizer.normalize(:openai, body) == %{
               prompt_tokens: 1000,
               completion_tokens: 50,
               cache_read_tokens: 800,
               cache_creation_tokens: 120
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

    test "recovers the cached count from Fireworks headers when the body omits it" do
      # Fireworks Serverless: caching is on by default, the body may carry no
      # prompt_tokens_details, and the split lands in the response headers.
      chunk = %{"usage" => %{"prompt_tokens" => 1000, "completion_tokens" => 50}}

      headers = [
        {"fireworks-prompt-tokens", "1000"},
        {"fireworks-cached-prompt-tokens", "800"}
      ]

      usage = UsageNormalizer.from_openai_stream_chunk(chunk, headers)

      assert usage.cache_read_tokens == 800
      assert usage.prompt_tokens == 1000
      assert usage.completion_tokens == 50
    end
  end

  describe "Fireworks cached-prompt headers" do
    @body %{"usage" => %{"prompt_tokens" => 1000, "completion_tokens" => 50}}

    test "falls back to the header when the body has no cached_tokens" do
      usage =
        UsageNormalizer.normalize(:openai, @body, [{"fireworks-cached-prompt-tokens", "750"}])

      assert usage.cache_read_tokens == 750
    end

    test "a body-reported cached count wins over the header" do
      body =
        Map.put(@body, "usage", %{
          "prompt_tokens" => 1000,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{"cached_tokens" => 900}
        })

      usage =
        UsageNormalizer.normalize(:openai, body, [{"fireworks-cached-prompt-tokens", "100"}])

      assert usage.cache_read_tokens == 900
    end

    test "absent header yields zero (unchanged behaviour)" do
      usage = UsageNormalizer.normalize(:openai, @body, [])

      assert usage.cache_read_tokens == 0
    end

    test "malformed header value degrades to 0 instead of crashing" do
      assert UsageNormalizer.normalize(:openai, @body, [{"fireworks-cached-prompt-tokens", "abc"}])
             |> Map.get(:cache_read_tokens) == 0
    end

    test "nil headers is tolerated (arity-3 called without headers)" do
      usage = UsageNormalizer.normalize(:openai, @body, nil)

      assert usage.cache_read_tokens == 0
    end
  end
end
