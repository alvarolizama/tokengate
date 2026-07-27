defmodule Tokengate.Proxy.ReasoningTest do
  @moduledoc """
  Tests for Tokengate.Proxy.Reasoning — parses think/effort flags from
  client payloads (each provider names them differently).
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.Reasoning

  describe "parse/1" do
    test "payload sin flags de razonamiento" do
      assert Reasoning.parse(%{"model" => "gpt-4o", "messages" => []}) == {false, nil}
    end

    test "OpenAI reasoning_effort plano" do
      assert Reasoning.parse(%{"reasoning_effort" => "high"}) == {true, "high"}
      assert Reasoning.parse(%{"reasoning_effort" => "low"}) == {true, "low"}
    end

    test "OpenAI reasoning.effort anidado" do
      assert Reasoning.parse(%{"reasoning" => %{"effort" => "medium"}}) == {true, "medium"}
    end

    test "reasoning_effort none/minimal no cuenta como think" do
      assert Reasoning.parse(%{"reasoning_effort" => "none"}) == {false, "none"}
      assert Reasoning.parse(%{"reasoning_effort" => "minimal"}) == {false, "minimal"}
    end

    test "Anthropic/GLM thinking enabled" do
      assert Reasoning.parse(%{"thinking" => %{"type" => "enabled", "budget_tokens" => 10_000}}) ==
               {true, nil}
    end

    test "thinking disabled no cuenta" do
      assert Reasoning.parse(%{"thinking" => %{"type" => "disabled"}}) == {false, nil}
    end

    test "thinking booleano" do
      assert Reasoning.parse(%{"thinking" => true}) == {true, nil}
      assert Reasoning.parse(%{"thinking" => false}) == {false, nil}
    end

    test "reasoning.enabled booleano" do
      assert Reasoning.parse(%{"reasoning" => %{"enabled" => true}}) == {true, nil}
      assert Reasoning.parse(%{"reasoning" => %{"enabled" => false}}) == {false, nil}
    end

    test "effort gana sobre reasoning.effort cuando ambos están" do
      assert Reasoning.parse(%{
               "reasoning_effort" => "high",
               "reasoning" => %{"effort" => "low"}
             }) == {true, "high"}
    end
  end
end
