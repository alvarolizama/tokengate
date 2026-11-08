defmodule Tokengate.Proxy.DecisionsTranslatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.DecisionsTranslator

  # El request del ejemplo de la doc de TypeSafe, en el shape OpenAI que el
  # gateway expone en /v1/decisions.
  @openai_request %{
    "model" => "jev-latest",
    "input" =>
      "Customer message: I was charged twice for my order last week and nobody has replied.",
    "questions" => [
      %{
        "type" => "choice",
        "name" => "route",
        "instructions" => "Which team should handle this?",
        "choices" => [
          %{"value" => "billing", "description" => "Payments and refunds"},
          %{"value" => "shipping", "description" => nil},
          %{"value" => "technical", "description" => nil}
        ]
      },
      %{"type" => "predicate", "name" => "angry", "instructions" => "Is the customer angry?"},
      %{
        "type" => "score",
        "name" => "urgency",
        "instructions" => "How urgent is this?",
        "levels" => [
          %{"label" => "can wait"},
          %{"label" => "this week"},
          %{"label" => "today"},
          %{"label" => "right now"}
        ]
      }
    ]
  }

  # La respuesta del ejemplo (OpenJev en llama.cpp), shape System One.
  @systemone_response %{
    "model" => "openjev",
    "answers" => %{
      "route" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.9998, "shipping" => 0.0001, "technical" => 0.0001},
        "confidence" => 0.9997
      },
      "angry" => %{"type" => "noul", "noul" => 0.6328},
      "urgency" => %{
        "type" => "score",
        "score" => 2.0858,
        "legend" => %{"0" => "can wait", "1" => "this week", "2" => "today", "3" => "right now"},
        "probabilities" => %{"0" => 0.0023, "1" => 0.116, "2" => 0.6753, "3" => 0.2064},
        "confidence" => 0.673
      }
    },
    "usage" => %{"input_tokens" => 239, "output_tokens" => 0}
  }

  describe "validate/1" do
    test "acepta el request válido" do
      assert :ok = DecisionsTranslator.validate(@openai_request)
    end

    test "rechaza choices malformados sin explotar" do
      bad = %{
        "model" => "jev-latest",
        "input" => "estado",
        "questions" => [
          %{"type" => "choice", "name" => "route", "choices" => ["billing", "technical"]}
        ]
      }

      assert {:error, msg} = DecisionsTranslator.validate(bad)
      assert msg =~ "choices"
    end

    test "rechaza un type fuera del vocabulario" do
      bad = %{
        "model" => "jev-latest",
        "input" => "estado",
        "questions" => [%{"type" => "ranking", "name" => "x"}]
      }

      assert {:error, msg} = DecisionsTranslator.validate(bad)
      assert msg =~ "predicate, choice, score"
    end

    test "rechaza score sin levels y choice sin choices" do
      no_levels = %{
        "model" => "j",
        "input" => "s",
        "questions" => [%{"type" => "score", "name" => "u", "instructions" => "?"}]
      }

      assert {:error, msg} = DecisionsTranslator.validate(no_levels)
      assert msg =~ "levels"

      no_choices = %{
        "model" => "j",
        "input" => "s",
        "questions" => [%{"type" => "choice", "name" => "r", "instructions" => "?"}]
      }

      assert {:error, msg} = DecisionsTranslator.validate(no_choices)
      assert msg =~ "choices"
    end

    test "rechaza una pregunta que no es objeto y un name no-string" do
      not_object = %{"model" => "j", "input" => "s", "questions" => ["hola"]}
      assert {:error, msg} = DecisionsTranslator.validate(not_object)
      assert msg =~ "must be an object"

      bad_name = %{
        "model" => "j",
        "input" => "s",
        "questions" => [%{"type" => "predicate", "name" => 42, "instructions" => "?"}]
      }

      assert {:error, msg} = DecisionsTranslator.validate(bad_name)
      assert msg =~ "name"
    end
  end

  describe "to_systemone/1" do
    test "traduce el envelope completo: state, questions map y criteria" do
      assert {:ok, request, ctx} = DecisionsTranslator.to_systemone(@openai_request)

      assert request["model"] == "jev-latest"
      assert request["state"] =~ "charged twice"

      assert request["questions"]["route"] == %{
               "type" => "choice",
               "instructions" => "Which team should handle this?",
               "criteria" => %{
                 "billing" => "Payments and refunds",
                 "shipping" => nil,
                 "technical" => nil
               }
             }

      assert request["questions"]["angry"] == %{
               "type" => "noul",
               "instructions" => "Is the customer angry?"
             }

      assert request["questions"]["urgency"] == %{
               "type" => "score",
               "instructions" => "How urgent is this?",
               "criteria" => ["can wait", "this week", "today", "right now"]
             }

      # El ctx lleva el orden y los niveles para restaurar la respuesta.
      assert Enum.map(ctx.questions, & &1.name) == ["route", "angry", "urgency"]
      assert Enum.map(ctx.questions, & &1.type) == ["choice", "predicate", "score"]
    end

    test "input como array de mensajes se vuelve state estructurado" do
      request = %{
        "model" => "jev-latest",
        "input" => [
          %{"role" => "user", "content" => "mensaje del cliente"},
          %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "segunda parte"}]}
        ],
        "questions" => [
          %{"type" => "predicate", "name" => "urgent", "instructions" => "¿urge?"}
        ]
      }

      assert {:ok, translated, _ctx} = DecisionsTranslator.to_systemone(request)

      assert translated["state"] == [
               %{"role" => "user", "content" => "mensaje del cliente"},
               %{"role" => "user", "content" => "segunda parte"}
             ]
    end

    test "preguntas sin nombre toman un id sintetizado" do
      request = %{
        "model" => "jev-latest",
        "input" => "estado",
        "questions" => [
          %{"type" => "predicate", "instructions" => "¿sí?"}
        ]
      }

      assert {:ok, translated, ctx} = DecisionsTranslator.to_systemone(request)
      assert Map.has_key?(translated["questions"], "q0")

      assert [%{name: "q0", type: "predicate"}] =
               Enum.map(ctx.questions, &Map.take(&1, [:name, :type]))
    end

    test "rechaza input_image en validate/1 y request sin preguntas" do
      images = %{
        "model" => "jev-latest",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_image", "image_url" => "data:image/png;base64,x"}]
          }
        ],
        "questions" => [%{"type" => "predicate", "name" => "a", "instructions" => "b"}]
      }

      assert {:error, msg} = DecisionsTranslator.validate(images)
      assert msg =~ "input_image"

      # El traductor asume validate/1 pasado: sin preguntas construye el
      # envelope vacío (el 400 lo puso el controller antes de rutear).
      assert {:ok, %{"questions" => questions}, _ctx} =
               DecisionsTranslator.to_systemone(%{"model" => "x", "input" => "s"})

      assert questions == %{}
    end
  end

  describe "from_systemone/2" do
    test "restaura el shape OpenAI: orden, nombres y labels de score" do
      assert {:ok, _request, ctx} = DecisionsTranslator.to_systemone(@openai_request)
      response = DecisionsTranslator.from_systemone(@systemone_response, ctx)

      assert Enum.map(response["answers"], & &1["name"]) == ["route", "angry", "urgency"]

      predicate = Enum.find(response["answers"], &(&1["name"] == "angry"))

      assert predicate == %{
               "type" => "predicate",
               "name" => "angry",
               "probability" => 0.6328
             }

      choice = Enum.find(response["answers"], &(&1["name"] == "route"))
      assert choice["choice"] == "billing"
      assert choice["confidence"] == 0.9997

      assert %{"value" => "billing", "probability" => 0.9998} in choice["probabilities"]

      score = Enum.find(response["answers"], &(&1["name"] == "urgency"))
      assert score["score"] == 2.0858

      # Los índices de System One vuelven a ser los labels del cliente.
      assert score["probabilities"] == [
               %{"value" => "can wait", "probability" => 0.0023},
               %{"value" => "this week", "probability" => 0.116},
               %{"value" => "today", "probability" => 0.6753},
               %{"value" => "right now", "probability" => 0.2064}
             ]

      # Output tokens gratis: el usage OpenAI sólo lleva input.
      assert response["usage"] == %{
               "input_tokens" => 239,
               "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
             }
    end

    test "sin usage upstream, la llave se omite (el proxy estima, no factura $0)" do
      assert {:ok, _request, ctx} = DecisionsTranslator.to_systemone(@openai_request)

      response = DecisionsTranslator.from_systemone(Map.delete(@systemone_response, "usage"), ctx)
      refute Map.has_key?(response, "usage")
    end

    test "pregunta sin respuesta: nil en vez de un cero inventado" do
      assert {:ok, _request, ctx} = DecisionsTranslator.to_systemone(@openai_request)

      partial = %{
        model: "openjev",
        answers: %{"route" => %{"type" => "choice", "choice" => "billing"}}
      }

      response = DecisionsTranslator.from_systemone(partial, ctx)

      angry = Enum.find(response["answers"], &(&1["name"] == "angry"))
      assert angry["probability"] == nil
      urgency = Enum.find(response["answers"], &(&1["name"] == "urgency"))
      assert urgency["score"] == nil
      assert urgency["probabilities"] == []
    end

    test "choice con value booleano restaura el tipo original" do
      request = %{
        "model" => "jev-latest",
        "input" => "estado",
        "questions" => [
          %{
            "type" => "choice",
            "name" => "refund",
            "instructions" => "¿Pide reembolso?",
            "choices" => [%{"value" => true}, %{"value" => false}]
          }
        ]
      }

      assert {:ok, translated, ctx} = DecisionsTranslator.to_systemone(request)
      # En el wire System One las claves son strings
      assert translated["questions"]["refund"]["criteria"] == %{"true" => nil, "false" => nil}

      response =
        DecisionsTranslator.from_systemone(
          %{
            "answers" => %{
              "refund" => %{
                "type" => "choice",
                "choice" => "true",
                "probabilities" => %{"true" => 0.9, "false" => 0.1},
                "confidence" => 0.8
              }
            }
          },
          ctx
        )

      answer = Enum.find(response["answers"], &(&1["name"] == "refund"))
      # El valor vuelve en su tipo original, no como string
      assert answer["choice"] == true
      assert %{"value" => true, "probability" => 0.9} in answer["probabilities"]
    end

    test "score con más de 10 niveles: las probabilidades salen ordenadas por índice" do
      labels = for i <- 0..11, do: "L#{i}"
      probs = Map.new(0..11, fn i -> {Integer.to_string(i), 1 / 12} end)

      request = %{
        "model" => "jev-latest",
        "input" => "estado",
        "questions" => [
          %{
            "type" => "score",
            "name" => "rubric",
            "instructions" => "?",
            "levels" => Enum.map(labels, &%{"label" => &1})
          }
        ]
      }

      assert {:ok, _translated, ctx} = DecisionsTranslator.to_systemone(request)

      response =
        DecisionsTranslator.from_systemone(
          %{
            "answers" => %{
              "rubric" => %{"type" => "score", "score" => 5.5, "probabilities" => probs}
            }
          },
          ctx
        )

      rubric = Enum.find(response["answers"], &(&1["name"] == "rubric"))
      values = Enum.map(rubric["probabilities"], & &1["value"])
      assert values == labels
    end
  end
end
