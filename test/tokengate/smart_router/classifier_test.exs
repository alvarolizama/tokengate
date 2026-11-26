defmodule Tokengate.SmartRouter.ClassifierTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.Classifier
  alias Tokengate.SmartRouter.RequestAnalyzer
  alias Tokengate.SmartRouterFixtures, as: F

  defp use_cases do
    [
      F.use_case("fast"),
      F.use_case("writing"),
      F.use_case("coding_implement", %{requires_tools: true})
    ]
  end

  defp decision_model do
    F.decision_model(%{
      lane: %{
        provider: %{key: "openai"},
        credential: %{id: "cred-decider"},
        provider_model: "decider-upstream"
      }
    })
  end

  defp body(use_case, opts \\ %{}) do
    Map.merge(
      %{
        "answers" => [
          %{"name" => "use_case", "choice" => use_case, "confidence" => 0.7},
          %{"name" => "effort", "choice" => "high", "confidence" => 0.6}
        ],
        "usage" => %{"input_tokens" => 21}
      },
      opts
    )
  end

  test "asks one choice question per use case plus the unknown effort" do
    payload = F.payload("Implement a small endpoint")
    analysis = RequestAnalyzer.analyze(payload)
    parent = self()

    post = fn _provider, _credential, request, _opts ->
      send(parent, {:request, request})
      {:ok, body("coding_implement"), 7, []}
    end

    assert {:ok, result} =
             Classifier.classify(decision_model(), analysis, use_cases(),
               post_fun: post,
               timeout_ms: 1_000
             )

    assert result.use_case_key == "coding_implement"
    assert result.effort == "high"
    assert result.confidence == 0.7
    assert result.usage == %{"input_tokens" => 21}
    assert result.source == "classifier"
    assert result.model_id == "model-decider"

    assert_received {:request, request}
    assert request["model"] == "decider-upstream"

    assert [use_case_question, effort_question] = request["questions"]
    assert use_case_question["name"] == "use_case"

    assert Enum.map(use_case_question["choices"], & &1["value"]) ==
             ~w(fast writing coding_implement)

    assert effort_question["name"] == "effort"
    assert Enum.map(effort_question["choices"], & &1["value"]) == ~w(low medium high)
  end

  test "skips the effort question when the client already declared it" do
    analysis = RequestAnalyzer.analyze(F.payload("think hard", %{"reasoning_effort" => "high"}))
    parent = self()

    post = fn _p, _c, request, _o ->
      send(parent, {:request, request})
      {:ok, %{"answers" => [%{"name" => "use_case", "choice" => "writing"}]}, 3, []}
    end

    assert {:ok, result} =
             Classifier.classify(decision_model(), analysis, use_cases(), post_fun: post)

    assert_received {:request, request}
    assert [%{"name" => "use_case"}] = request["questions"]
    assert result.effort == "high"
  end

  test "confidence falls back to the max probability when the answer omits it" do
    analysis = RequestAnalyzer.analyze(F.payload("write an email"))

    post = fn _p, _c, _request, _o ->
      {:ok,
       %{
         "answers" => [
           %{
             "name" => "use_case",
             "choice" => "writing",
             "probabilities" => [
               %{"value" => "writing", "probability" => 0.55},
               %{"value" => "fast", "probability" => 0.45}
             ]
           }
         ]
       }, 4, []}
    end

    assert {:ok, result} =
             Classifier.classify(decision_model(), analysis, use_cases(), post_fun: post)

    assert result.confidence == 0.55
  end

  test "the input is plain text, truncated and carries capability metadata" do
    long = String.duplicate("palabra ", 400)

    analysis =
      RequestAnalyzer.analyze(%{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => long},
              %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
            ]
          }
        ]
      })

    parent = self()

    post = fn _p, _c, request, _o ->
      send(parent, {:request, request})
      {:ok, body("fast"), 3, []}
    end

    assert {:ok, _} =
             Classifier.classify(decision_model(), analysis, use_cases(),
               post_fun: post,
               context_chars: 120
             )

    assert_received {:request, request}
    input = request["input"]
    assert is_binary(input)
    assert String.starts_with?(input, String.slice(long, 0, 120))
    assert input =~ "\"has_vision\":true"
    refute input =~ "input_image"
  end

  test "times out without hanging the caller" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o ->
      Process.sleep(5_000)
      {:ok, body("fast"), 1, []}
    end

    assert {:error, :timeout} =
             Classifier.classify(decision_model(), analysis, use_cases(),
               post_fun: post,
               timeout_ms: 20
             )
  end

  test "an upstream error is returned, not raised" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o -> {:error, :server_error, 500, "boom"} end

    assert {:error, {:server_error, "boom"}} =
             Classifier.classify(decision_model(), analysis, use_cases(), post_fun: post)
  end

  test "a choice outside the offered use cases is rejected" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o -> {:ok, body("nope"), 2, []} end

    assert {:error, :unknown_use_case} =
             Classifier.classify(decision_model(), analysis, use_cases(), post_fun: post)
  end

  test "a response without answers is invalid" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o -> {:ok, %{"choices" => []}, 2, []} end

    assert {:error, :invalid_response} =
             Classifier.classify(decision_model(), analysis, use_cases(), post_fun: post)
  end

  # ---------------------------------------------------------------------------
  # `model_type: "llm"` — a chat model as the classifier
  # ---------------------------------------------------------------------------

  defp llm_model do
    F.decision_model(%{
      model_type: "llm",
      lane: %{
        model_type: "llm",
        provider: %{key: "openai"},
        credential: %{id: "cred-llm"},
        provider_model: "small-chat"
      }
    })
  end

  defp chat_body(content) do
    %{
      "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 40, "completion_tokens" => 12}
    }
  end

  test "an llm decision model asks for pure JSON and parses a fenced chat answer" do
    analysis = RequestAnalyzer.analyze(F.payload("Implement a small endpoint"))
    parent = self()

    content =
      "```json\n" <>
        Jason.encode!(%{
          "use_case" => "coding_implement",
          "effort" => "medium",
          "confidence" => 0.83
        }) <> "\n```"

    post = fn _provider, _credential, request, _opts ->
      send(parent, {:request, request})
      {:ok, chat_body(content), 11, []}
    end

    assert {:ok, result} =
             Classifier.classify(llm_model(), analysis, use_cases(),
               post_fun: post,
               timeout_ms: 1_000
             )

    assert result.use_case_key == "coding_implement"
    assert result.effort == "medium"
    assert_in_delta result.confidence, 0.83, 0.001
    assert result.usage == %{"prompt_tokens" => 40, "completion_tokens" => 12}
    assert result.source == "classifier"
    assert result.model_id == "model-decider"

    assert_received {:request, request}
    assert request["model"] == "small-chat"
    assert request["temperature"] == 0
    assert request["max_tokens"] == 150
    # The chat wire, not the decisions one.
    refute Map.has_key?(request, "questions")
    refute Map.has_key?(request, "input")

    assert [system, user] = request["messages"]
    assert system["role"] == "system"
    assert system["content"] =~ "PURE JSON"
    assert system["content"] =~ "coding_implement"
    assert system["content"] =~ "tags: coding_implement"
    refute system["content"] =~ "input_image"

    assert user["role"] == "user"
    assert user["content"] =~ "Implement a small endpoint"
    assert user["content"] =~ "\"has_tools\""
  end

  test "an llm answer keeps the client's declared effort" do
    analysis = RequestAnalyzer.analyze(F.payload("think hard", %{"reasoning_effort" => "high"}))

    content = Jason.encode!(%{"use_case" => "writing", "effort" => "low", "confidence" => 0.6})
    post = fn _p, _c, _r, _o -> {:ok, chat_body(content), 4, []} end

    assert {:ok, result} = Classifier.classify(llm_model(), analysis, use_cases(), post_fun: post)
    assert result.effort == "high"
    assert result.use_case_key == "writing"
  end

  test "an llm answer that is not JSON is invalid" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o -> {:ok, chat_body("sure! writing"), 3, []} end

    assert {:error, :invalid_response} =
             Classifier.classify(llm_model(), analysis, use_cases(), post_fun: post)
  end

  test "an llm answer naming an unknown use case is rejected" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    content = Jason.encode!(%{"use_case" => "ghost", "effort" => "low", "confidence" => 0.9})
    post = fn _p, _c, _r, _o -> {:ok, chat_body(content), 3, []} end

    assert {:error, :unknown_use_case} =
             Classifier.classify(llm_model(), analysis, use_cases(), post_fun: post)
  end

  test "an llm response with no choices is invalid" do
    analysis = RequestAnalyzer.analyze(F.payload("hola"))

    post = fn _p, _c, _r, _o -> {:ok, %{"choices" => []}, 3, []} end

    assert {:error, :invalid_response} =
             Classifier.classify(llm_model(), analysis, use_cases(), post_fun: post)
  end
end
