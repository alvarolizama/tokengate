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

      # OpenAI's prompt_tokens includes cached tokens — prompt_tokens is
      # normalized to regular (non-cached) input: 100 - 20 = 80.
      assert UsageNormalizer.normalize(:openai, body) == %{
               prompt_tokens: 80,
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

  describe "normalize/2 anthropic" do
    test "normalizes a full response with cache tokens" do
      body = %{
        "usage" => %{
          "input_tokens" => 200,
          "output_tokens" => 80,
          "cache_read_input_tokens" => 150,
          "cache_creation_input_tokens" => 30
        }
      }

      assert UsageNormalizer.normalize(:anthropic, body) == %{
               prompt_tokens: 200,
               completion_tokens: 80,
               cache_read_tokens: 150,
               cache_creation_tokens: 30
             }
    end

    test "no usage returns nil" do
      assert UsageNormalizer.normalize(:anthropic, %{"content" => []}) == nil
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

  describe "anthropic stream accumulator" do
    test "message_start sets input, message_delta updates output cumulatively" do
      acc = UsageNormalizer.anthropic_accumulator()

      acc =
        UsageNormalizer.apply_anthropic_event(acc, %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{
              "input_tokens" => 42,
              "cache_read_input_tokens" => 10,
              "cache_creation_input_tokens" => 5
            }
          }
        })

      acc =
        UsageNormalizer.apply_anthropic_event(acc, %{
          "type" => "message_delta",
          "usage" => %{"output_tokens" => 8}
        })

      acc =
        UsageNormalizer.apply_anthropic_event(acc, %{
          "type" => "message_delta",
          "usage" => %{"output_tokens" => 15}
        })

      acc = UsageNormalizer.apply_anthropic_event(acc, %{"type" => "content_block_delta"})

      assert UsageNormalizer.finalize_anthropic(acc) == %{
               prompt_tokens: 42,
               completion_tokens: 15,
               cache_read_tokens: 10,
               cache_creation_tokens: 5
             }
    end
  end
end
