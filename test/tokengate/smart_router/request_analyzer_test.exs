defmodule Tokengate.SmartRouter.RequestAnalyzerTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.RequestAnalyzer

  test "counts tools and tool_calls besides the messages" do
    plain = RequestAnalyzer.analyze(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

    with_tools =
      RequestAnalyzer.analyze(%{
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "search",
              "description" => String.duplicate("look up a thing ", 20),
              "parameters" => %{
                "type" => "object",
                "properties" => %{"q" => %{"type" => "string"}}
              }
            }
          }
        ],
        "messages" => [
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "search", "arguments" => ~s({"q":"elixir"})}
              }
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "result"}
        ]
      })

    assert with_tools.prompt_tokens > plain.prompt_tokens
    assert with_tools.has_tools
  end

  test "detects vision, structured output and an open tool loop" do
    analysis =
      RequestAnalyzer.analyze(%{
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "out", "schema" => %{}}
        },
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "read this"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "done"}
        ]
      })

    assert analysis.has_vision
    assert analysis.has_structured_output
    assert analysis.tool_loop
  end

  test "structured output is false for a plain text response_format" do
    refute RequestAnalyzer.analyze(%{"response_format" => %{"type" => "text"}}).has_structured_output
  end

  test "maps reasoning_effort and thinking to an effort tier" do
    assert RequestAnalyzer.analyze(%{"reasoning_effort" => "medium"}).effort == "medium"
    assert RequestAnalyzer.analyze(%{"reasoning" => %{"effort" => "high"}}).effort == "high"
    assert RequestAnalyzer.analyze(%{"thinking" => %{"type" => "enabled"}}).effort == "high"
    assert RequestAnalyzer.analyze(%{"reasoning_effort" => "none"}).effort == nil
    assert RequestAnalyzer.analyze(%{}).effort == nil
  end

  test "uses max_tokens when present, otherwise a bounded heuristic" do
    assert RequestAnalyzer.analyze(%{"max_tokens" => 32}).estimated_output_tokens == 32

    analysis =
      RequestAnalyzer.analyze(%{"messages" => [%{"role" => "user", "content" => "hola"}]})

    assert analysis.estimated_output_tokens == 256

    long =
      RequestAnalyzer.analyze(%{
        "messages" => [%{"role" => "user", "content" => String.duplicate("x", 32_000)}]
      })

    assert long.estimated_output_tokens == 2_048
  end

  test "extracts the last user message from string and multi-part content" do
    analysis =
      RequestAnalyzer.analyze(%{
        "messages" => [
          %{"role" => "user", "content" => "first"},
          %{"role" => "assistant", "content" => "reply"},
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "last"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
            ]
          }
        ]
      })

    assert analysis.last_user_message == "last"
  end

  test "carries rule-matching context" do
    analysis =
      RequestAnalyzer.analyze(%{}, %{agent_type: "codex", group_id: "g1", service_id: "s1"})

    assert analysis.agent_type == "codex"
    assert analysis.group_id == "g1"
    assert analysis.service_id == "s1"
  end
end
