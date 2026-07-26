defmodule Tokengate.Proxy.TokenEstimatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.TokenEstimator

  describe "estimate_text/1" do
    test "empty string is zero" do
      assert TokenEstimator.estimate_text("") == 0
    end

    test "uses ceil(chars/4)" do
      assert TokenEstimator.estimate_text("abcd") == 1
      assert TokenEstimator.estimate_text("abcde") == 2
      assert TokenEstimator.estimate_text(String.duplicate("a", 100)) == 25
    end

    test "handles unicode by character count" do
      assert TokenEstimator.estimate_text("áéíóú") == 2
    end
  end

  describe "estimate_messages/1" do
    test "sums content plus per-message overhead" do
      messages = [
        %{"role" => "user", "content" => String.duplicate("a", 40)}
      ]

      # 10 content tokens + 4 overhead
      assert TokenEstimator.estimate_messages(messages) == 14
    end

    test "handles multi-part content with text and images" do
      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => String.duplicate("a", 40)},
            %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
          ]
        }
      ]

      # 10 text + 85 image + 4 overhead
      assert TokenEstimator.estimate_messages(messages) == 99
    end

    test "nil content counts only overhead" do
      assert TokenEstimator.estimate_messages([%{"role" => "assistant", "content" => nil}]) == 4
    end
  end

  describe "estimate_completion/1" do
    test "estimates accumulated stream text" do
      assert TokenEstimator.estimate_completion(String.duplicate("b", 8)) == 2
    end
  end
end
