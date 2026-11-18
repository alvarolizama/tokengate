defmodule Tokengate.Proxy.RerankTest do
  @moduledoc """
  The rerank contract, without a network: the canonical input gate, the
  normalization of every documented upstream answer (fixtures captured from
  the wire shapes in the shaping, F59/F60), and the request-side shape
  selector.

  `Rerank.post/4` — the half that talks HTTP — is exercised end to end in
  `TokengateWeb.ProxyControllerTest` against the Bandit upstream.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.{RawResponse, Rerank}

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "model" => "qwen3-reranker-8b",
        "query" => "what is the capital of France?",
        "documents" => ["Paris is the capital of France.", "Berlin is in Germany."]
      },
      overrides
    )
  end

  describe "validate/1 — the canonical input" do
    test "accepts strings, objects with text, and an optional top_n" do
      assert Rerank.validate(payload()) == :ok

      assert Rerank.validate(
               payload(%{
                 "documents" => [
                   "a plain string",
                   %{"text" => "an object document", "metadata" => %{"id" => 7}}
                 ],
                 "top_n" => 2
               })
             ) == :ok

      # JSON numbers arrive as floats: a whole positive float is a count.
      assert Rerank.validate(payload(%{"top_n" => 3.0})) == :ok
    end

    test "query is required and must be text" do
      assert {:error, message} = Rerank.validate(payload(%{"query" => nil}))
      assert message =~ "query is required"

      assert {:error, _} = Rerank.validate(payload(%{"query" => "   "}))
      assert {:error, _} = Rerank.validate(payload(%{"query" => 42}))
    end

    test "documents must be a non-empty array of text" do
      assert {:error, message} = Rerank.validate(payload(%{"documents" => nil}))
      assert message =~ "documents is required"

      assert {:error, _} = Rerank.validate(payload(%{"documents" => []}))
      assert {:error, _} = Rerank.validate(payload(%{"documents" => "one string"}))

      assert {:error, message} = Rerank.validate(payload(%{"documents" => ["ok", 42]}))
      assert message =~ "documents[1]"

      assert {:error, message} = Rerank.validate(payload(%{"documents" => [%{"body" => "x"}]}))
      assert message =~ "documents[0]"

      assert {:error, _} = Rerank.validate(payload(%{"documents" => [""]}))
    end

    test "top_n is a positive integer when present" do
      assert {:error, message} = Rerank.validate(payload(%{"top_n" => 0}))
      assert message =~ "top_n must be a positive integer"

      assert {:error, _} = Rerank.validate(payload(%{"top_n" => 2.5}))
      assert {:error, _} = Rerank.validate(payload(%{"top_n" => "5"}))
      assert {:error, _} = Rerank.validate(payload(%{"top_n" => -1}))
    end

    test "a non-object body is a caller error, not a crash" do
      assert {:error, message} = Rerank.validate(["not", "a", "map"])
      assert message =~ "JSON object"
    end
  end

  describe "document_texts/1" do
    test "reads strings and object texts in order, skipping what it cannot read" do
      assert Rerank.document_texts([
               "one",
               %{"text" => "two", "metadata" => %{}},
               %{"body" => "ignored"},
               42,
               nil
             ]) == ["one", "two"]
    end

    test "a nil documents field is no text at all" do
      assert Rerank.document_texts(nil) == []
      assert Rerank.document_texts(%{}) == []
    end
  end

  describe "normalize/1 — one canonical answer for five wires" do
    # Fireworks: docs.fireworks.ai/api-reference/rerank-documents. It is the
    # only upstream that answers `data[]`, echoes the document and reports
    # `usage` at the top level.
    test "absorbs Fireworks' data[] + usage" do
      answer = %{
        "object" => "list",
        "model" => "accounts/fireworks/models/qwen3-reranker-8b",
        "data" => [
          %{
            "index" => 0,
            "relevance_score" => 0.9812,
            "document" => "Paris is the capital of France."
          },
          %{
            "index" => 1,
            "relevance_score" => 0.0123,
            "document" => "Berlin is in Germany."
          }
        ],
        "usage" => %{"prompt_tokens" => 42, "total_tokens" => 42}
      }

      assert {:ok, body} = Rerank.normalize(answer)

      assert body["results"] == [
               %{"index" => 0, "relevance_score" => 0.9812},
               %{"index" => 1, "relevance_score" => 0.0123}
             ]

      assert body["usage"] == %{
               "prompt_tokens" => 42,
               "completion_tokens" => 0,
               "total_tokens" => 42
             }

      refute Map.has_key?(body, "data")
      refute Map.has_key?(body, "object")
      refute Map.has_key?(body, "model")
    end

    test "absorbs the results[] envelope of OpenRouter / NaN / oMLX" do
      answer = %{
        "id" => "rerank-1",
        "results" => [
          %{"index" => 1, "relevance_score" => 0.87, "document" => %{"text" => "b"}},
          %{"index" => 0, "relevance_score" => 0.12, "document" => %{"text" => "a"}}
        ]
      }

      assert {:ok, body} = Rerank.normalize(answer)

      assert body["results"] == [
               %{"index" => 1, "relevance_score" => 0.87},
               %{"index" => 0, "relevance_score" => 0.12}
             ]

      # No `usage` block and no usage counters anywhere: the canonical answer
      # carries no invented usage (the cost path estimates from the request).
      refute Map.has_key?(body, "usage")
    end

    # Helmcode: the same `results[]` envelope plus its own billing block.
    test "absorbs Helmcode's meta.billed_units into the canonical usage" do
      answer = %{
        "results" => [%{"index" => 0, "relevance_score" => 0.5}],
        "meta" => %{"billed_units" => %{"input_tokens" => 120}, "model" => "rerank"}
      }

      assert {:ok, body} = Rerank.normalize(answer)

      assert body["results"] == [%{"index" => 0, "relevance_score" => 0.5}]
      assert body["usage"]["prompt_tokens"] == 120
      assert body["usage"]["total_tokens"] == 120
      refute Map.has_key?(body, "meta")
    end

    test "a billed_units block whose counters it cannot read reports no usage" do
      # The public docs name the block but not its inner keys: an unknown shape
      # must degrade to "no usage reported" — never a guessed number.
      answer = %{
        "results" => [%{"index" => 0, "relevance_score" => 0.5}],
        "meta" => %{"billed_units" => %{"units" => "flat", "period" => "month"}}
      }

      assert {:ok, body} = Rerank.normalize(answer)
      refute Map.has_key?(body, "usage")
    end

    test "keeps a reported cost, wherever the upstream put it" do
      in_usage = %{
        "results" => [%{"index" => 0, "relevance_score" => 0.5}],
        "usage" => %{"prompt_tokens" => 10, "cost" => 0.0000042}
      }

      assert {:ok, %{"usage" => %{"cost" => 0.0000042}}} = Rerank.normalize(in_usage)

      top_level = %{
        "results" => [%{"index" => 0, "relevance_score" => 0.5}],
        "cost" => "0.00007"
      }

      assert {:ok, %{"cost" => "0.00007"}} = Rerank.normalize(top_level)
    end

    test "a cost without readable counters still travels" do
      answer = %{
        "results" => [%{"index" => 0, "relevance_score" => 0.5}],
        "meta" => %{"billed_units" => %{"cost" => 0.0001}}
      }

      assert {:ok, body} = Rerank.normalize(answer)
      assert body["usage"] == %{"cost" => 0.0001}
    end

    test "an empty list is a valid ranking; a body with no list is a gateway error" do
      assert {:ok, %{"results" => []}} = Rerank.normalize(%{"results" => []})
      assert {:ok, %{"results" => []}} = Rerank.normalize(%{"data" => []})

      assert {:error, message} = Rerank.normalize(%{"answers" => []})
      assert message =~ "results[]"

      assert {:error, _} = Rerank.normalize(%{"results" => %{"not" => "a list"}})
    end

    test "results it cannot read are dropped; all unreadable is an error" do
      answer = %{
        "results" => [
          %{"index" => 0, "relevance_score" => 0.9},
          %{"index" => "0", "relevance_score" => 0.8},
          %{"index" => 1},
          %{"relevance_score" => 1.0},
          "not a result"
        ]
      }

      assert {:ok, %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]}} =
               Rerank.normalize(answer)

      assert {:error, _} = Rerank.normalize(%{"results" => [%{"index" => "x"}]})
    end

    test "a numeric string is a score, a whole float is an index" do
      answer = %{
        "results" => [%{"index" => 2.0, "relevance_score" => "0.75"}]
      }

      assert {:ok, %{"results" => [%{"index" => 2, "relevance_score" => 0.75}]}} =
               Rerank.normalize(answer)
    end

    test "a raw (non-JSON) 2xx body is a gateway error, never a passthrough" do
      raw = %RawResponse{body: "<html>", content_type: "text/html"}

      assert {:error, message} = Rerank.normalize(raw)
      assert message =~ "non-JSON"
    end
  end

  describe "shape/1 — the request wire is code, not row data" do
    test "Fireworks is the only :fireworks shape; everything else is :results" do
      assert Rerank.shape(%{key: "fireworks-ai"}) == :fireworks
      assert Rerank.shape(%{"key" => "fireworks-ai"}) == :fireworks

      assert Rerank.shape(%{key: "openrouter"}) == :results
      assert Rerank.shape(%{key: "nan"}) == :results
      assert Rerank.shape(%{key: "helmcode"}) == :results

      # A custom host (an oMLX box, a relay) and a provider with no key at all
      # speak the Cohere envelope by construction.
      assert Rerank.shape(%{key: nil, base_url: "http://127.0.0.1:8000/v1"}) == :results
      assert Rerank.shape(nil) == :results
    end
  end
end
