defmodule Tokengate.Proxy.TypeSafeAdapterTest do
  @moduledoc """
  TypeSafe dialect translation: chat ↔ System One.

  The HTTP transport is OpenAIAdapter's (already tested there); these tests
  pin the TRANSLATION — the request the upstream receives and the response
  the rest of the pipeline consumes.
  """
  use Tokengate.DataCase, async: true

  alias Tokengate.Proxy.TypeSafeAdapter

  @questions %{
    "is_urgent" => %{
      "type" => "noul",
      "instructions" => "Does this convey urgency?",
      "criteria" => %{"true" => "Time-sensitive", "false" => "No urgency"}
    }
  }

  describe "to_systemone/1" do
    test "maps messages to state and carries the question set" do
      messages = [%{"role" => "user", "content" => "Help! Payouts failing 3 days"}]

      assert {:ok, body} =
               TypeSafeAdapter.to_systemone(%{
                 "model" => "jev-latest",
                 "messages" => messages,
                 "questions" => @questions
               })

      assert body["state"] == messages
      assert body["model"] == "jev-latest"
      assert body["questions"] == @questions
    end

    test "a plain string state passes through" do
      assert {:ok, body} =
               TypeSafeAdapter.to_systemone(%{
                 "messages" => "hola",
                 "questions" => @questions
               })

      assert body["state"] == "hola"
    end

    test "no question set is a 400 — a decision model cannot generate text" do
      assert {:error, :bad_request, 400, message} =
               TypeSafeAdapter.to_systemone(%{"messages" => [], "model" => "jev-latest"})

      assert message =~ "questions"
    end

    test "an empty question map is also rejected" do
      assert {:error, :bad_request, 400, _} =
               TypeSafeAdapter.to_systemone(%{"messages" => [], "questions" => %{}})
    end
  end

  describe "from_systemone/1" do
    test "answers become the assistant content and keep the typed payload" do
      answers = %{"is_urgent" => %{"type" => "noul", "noul" => 0.92}}

      body =
        TypeSafeAdapter.from_systemone(%{
          "model" => "jev-1.13.0",
          "answers" => answers,
          "usage" => %{"input_tokens" => 312, "output_tokens" => 48}
        })

      assert [%{"message" => %{"content" => content}}] = body["choices"]
      assert Jason.decode!(content) == answers
      assert body["systemone"]["answers"] == answers
      assert body["model"] == "jev-1.13.0"
      assert body["object"] == "chat.completion"
    end

    test "usage maps to the OpenAI counter names" do
      body =
        TypeSafeAdapter.from_systemone(%{
          "answers" => %{},
          "usage" => %{"input_tokens" => 312, "output_tokens" => 48}
        })

      assert body["usage"]["prompt_tokens"] == 312
      assert body["usage"]["completion_tokens"] == 48
    end

    test "a body without usage maps zero counters, not a crash" do
      body = TypeSafeAdapter.from_systemone(%{"answers" => %{}})
      assert body["usage"]["prompt_tokens"] == 0
      assert body["usage"]["completion_tokens"] == 0
    end
  end

  describe "dispatch" do
    test "the typesafe dialect resolves to the adapter" do
      assert Tokengate.Proxy.ProviderAdapter.dispatch(%{dialect: "typesafe"}) ==
               TypeSafeAdapter

      assert Tokengate.Proxy.ProviderAdapter.dispatch(%{"dialect" => "typesafe"}) ==
               TypeSafeAdapter
    end
  end

  describe "unsupported surfaces" do
    test "embeddings and media services are rejected, not delegated" do
      assert {:error, :bad_request, 400, _} =
               TypeSafeAdapter.embeddings(%{}, %{}, %{"input" => "x"})

      assert {:error, :bad_request, 400, _} =
               TypeSafeAdapter.service_post(%{}, %{}, :tts, %{}, [])
    end
  end
end
