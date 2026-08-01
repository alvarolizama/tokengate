defmodule Tokengate.Proxy.PromptOptimizerTest do
  @moduledoc """
  Tests for Tokengate.Proxy.PromptOptimizer — pure message-list transforms
  applied before forwarding the request to the upstream provider.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.PromptOptimizer

  describe "stable_prefix/1" do
    test "lista vacía devuelve lista vacía" do
      assert PromptOptimizer.stable_prefix([]) == []
    end

    test "sin system messages el orden se preserva" do
      messages = [
        %{"role" => "user", "content" => "hola"},
        %{"role" => "assistant", "content" => "qué tal"},
        %{"role" => "user", "content" => "adiós"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == messages
    end

    test "mueve los system messages al frente en su orden relativo" do
      messages = [
        %{"role" => "user", "content" => "u1"},
        %{"role" => "system", "content" => "S1"},
        %{"role" => "assistant", "content" => "a1"},
        %{"role" => "system", "content" => "S2"},
        %{"role" => "user", "content" => "u2"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system", "content" => "S1"},
               %{"role" => "system", "content" => "S2"},
               %{"role" => "user", "content" => "u1"},
               %{"role" => "assistant", "content" => "a1"},
               %{"role" => "user", "content" => "u2"}
             ]
    end

    test "deduplica system messages con content idéntico, conservando el primero" do
      messages = [
        %{"role" => "system", "content" => "regla"},
        %{"role" => "user", "content" => "u1"},
        %{"role" => "system", "content" => "regla"},
        %{"role" => "system", "content" => "otra"},
        %{"role" => "system", "content" => "regla"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system", "content" => "regla"},
               %{"role" => "system", "content" => "otra"},
               %{"role" => "user", "content" => "u1"}
             ]
    end

    test "no deduplica mensajes no-system aunque tengan content idéntico" do
      messages = [
        %{"role" => "user", "content" => "hola"},
        %{"role" => "user", "content" => "hola"},
        %{"role" => "assistant", "content" => "hola"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == messages
    end

    test "preserva el orden relativo entre mensajes no-system" do
      messages = [
        %{"role" => "system", "content" => "S"},
        %{"role" => "user", "content" => "u1"},
        %{"role" => "assistant", "content" => "a1"},
        %{"role" => "user", "content" => "u2"},
        %{"role" => "assistant", "content" => "a2"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system", "content" => "S"},
               %{"role" => "user", "content" => "u1"},
               %{"role" => "assistant", "content" => "a1"},
               %{"role" => "user", "content" => "u2"},
               %{"role" => "assistant", "content" => "a2"}
             ]
    end

    test "content no-string se queda intacto y participa del orden por posición" do
      vision_parts = [
        %{"type" => "text", "text" => "qué ves"},
        %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
      ]

      messages = [
        %{"role" => "user", "content" => "primero"},
        %{"role" => "user", "content" => vision_parts},
        %{"role" => "system", "content" => "S"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system", "content" => "S"},
               %{"role" => "user", "content" => "primero"},
               %{"role" => "user", "content" => vision_parts}
             ]
    end

    test "system messages con keys faltantes o content nil no rompen" do
      messages = [
        %{"role" => "user", "content" => "u1"},
        %{"role" => "system"},
        %{"role" => "system", "content" => nil}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system"},
               %{"role" => "system", "content" => nil},
               %{"role" => "user", "content" => "u1"}
             ]
    end

    test "system messages con content genuinamente distinto no colapsan" do
      messages = [
        %{"role" => "user", "content" => "u1"},
        %{"role" => "system", "content" => "regla uno"},
        %{"role" => "assistant", "content" => "a1"},
        %{"role" => "system", "content" => "regla dos"},
        %{"role" => "user", "content" => "u2"},
        %{"role" => "system", "content" => "regla tres"}
      ]

      assert PromptOptimizer.stable_prefix(messages) == [
               %{"role" => "system", "content" => "regla uno"},
               %{"role" => "system", "content" => "regla dos"},
               %{"role" => "system", "content" => "regla tres"},
               %{"role" => "user", "content" => "u1"},
               %{"role" => "assistant", "content" => "a1"},
               %{"role" => "user", "content" => "u2"}
             ]
    end
  end

  describe "lazy_cleanup/1" do
    test "lista vacía devuelve lista vacía" do
      assert PromptOptimizer.lazy_cleanup([]) == []
    end

    test "deduplica tool messages consecutivos con content idéntico" do
      messages = [
        %{"role" => "tool", "content" => "result"},
        %{"role" => "tool", "content" => "result"},
        %{"role" => "tool", "content" => "result"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "tool", "content" => "result"}
             ]
    end

    test "no deduplica tool messages no consecutivos aunque compartan content" do
      messages = [
        %{"role" => "tool", "content" => "same"},
        %{"role" => "user", "content" => "intermedio"},
        %{"role" => "tool", "content" => "same"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "no deduplica tool messages con content distinto" do
      messages = [
        %{"role" => "tool", "content" => "a"},
        %{"role" => "tool", "content" => "b"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "no deduplica otros roles aunque sean consecutivos con idéntico content" do
      messages = [
        %{"role" => "user", "content" => "x"},
        %{"role" => "user", "content" => "x"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "trunca content string de más de 40_000 chars con el marcador" do
      long = String.duplicate("a", 40_001)
      result = PromptOptimizer.lazy_cleanup([%{"role" => "user", "content" => long}])

      assert [%{"role" => "user", "content" => trimmed}] = result
      assert String.length(trimmed) == 40_000 + String.length("\n[... truncated]")
      assert trimmed |> String.ends_with?("\n[... truncated]")
      assert String.starts_with?(trimmed, String.duplicate("a", 40_000))
    end

    test "no trunca content de exactamente 40_000 chars" do
      content = String.duplicate("x", 40_000)

      assert PromptOptimizer.lazy_cleanup([%{"role" => "user", "content" => content}]) ==
               [%{"role" => "user", "content" => content}]
    end

    test "colapsa 3+ newlines a exactamente 2" do
      messages = [
        %{"role" => "user", "content" => "a\n\n\nb\n\n\n\n\nc"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "user", "content" => "a\n\nb\n\nc"}
             ]
    end

    test "respeta newlines simples y dobles" do
      messages = [
        %{"role" => "user", "content" => "línea 1\nlínea 2\n\nlínea 3"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "user", "content" => "línea 1\nlínea 2\n\nlínea 3"}
             ]
    end

    test "trim de whitespace al inicio y al final" do
      messages = [
        %{"role" => "user", "content" => "   \n  hola\t \n"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "user", "content" => "hola"}
             ]
    end

    test "no toca contenido no-string (list, map, nil)" do
      vision_parts = [
        %{"type" => "text", "text" => "  mira   "},
        %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
      ]

      nested = %{"nested" => "value with\n\n\n\n multiple newlines  "}

      messages = [
        %{"role" => "user", "content" => vision_parts},
        %{"role" => "user", "content" => nested},
        %{"role" => "user", "content" => nil}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "preserva el orden de los mensajes" do
      messages = [
        %{"role" => "system", "content" => "  S  "},
        %{"role" => "user", "content" => "u1"},
        %{"role" => "tool", "content" => "t1"},
        %{"role" => "tool", "content" => "t1"},
        %{"role" => "assistant", "content" => "a1"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "system", "content" => "S"},
               %{"role" => "user", "content" => "u1"},
               %{"role" => "tool", "content" => "t1"},
               %{"role" => "assistant", "content" => "a1"}
             ]
    end

    test "mensajes sin la key content se devuelven sin tocar" do
      message = %{"role" => "user"}
      assert PromptOptimizer.lazy_cleanup([message]) == [message]
    end

    test "tool message con content no-string no se deduplica" do
      vision_parts = [%{"type" => "text", "text" => "x"}]

      messages = [
        %{"role" => "tool", "content" => vision_parts},
        %{"role" => "tool", "content" => vision_parts}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "content no-string (list, map, nil) se devuelve completamente intacto" do
      vision_parts = [
        %{"type" => "text", "text" => "  mira   "},
        %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
      ]

      nested = %{"nested" => "value with\n\n\n\n multiple newlines  "}

      messages = [
        %{"role" => "user", "content" => vision_parts},
        %{"role" => "user", "content" => nested},
        %{"role" => "user", "content" => nil}
      ]

      # Cada content no-string pasa por la función sin alterarse en absoluto.
      assert PromptOptimizer.lazy_cleanup(messages) == messages

      assert PromptOptimizer.lazy_cleanup([%{"role" => "user", "content" => vision_parts}]) ==
               [%{"role" => "user", "content" => vision_parts}]

      assert PromptOptimizer.lazy_cleanup([%{"role" => "user", "content" => nested}]) ==
               [%{"role" => "user", "content" => nested}]

      assert PromptOptimizer.lazy_cleanup([%{"role" => "user", "content" => nil}]) ==
               [%{"role" => "user", "content" => nil}]
    end

    test "newlines simples y dobles no se colapsan (sólo 3+)" do
      messages = [
        # Un solo \n entre líneas: se preserva.
        %{"role" => "user", "content" => "línea 1\nlínea 2"},
        # \n\n (doble) como separador de párrafo: se preserva.
        %{"role" => "user", "content" => "párrafo 1\n\npárrafo 2"}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == messages
    end

    test "trim de whitespace al inicio y al final del string content" do
      # Tabs, espacios y newlines al principio y al final se eliminan.
      messages = [
        %{"role" => "user", "content" => "  hola"},
        %{"role" => "user", "content" => "\thola\t"},
        %{"role" => "user", "content" => "\n\n  hola mundo  \n\n"},
        %{"role" => "user", "content" => "   hola   "}
      ]

      assert PromptOptimizer.lazy_cleanup(messages) == [
               %{"role" => "user", "content" => "hola"},
               %{"role" => "user", "content" => "hola"},
               %{"role" => "user", "content" => "hola mundo"},
               %{"role" => "user", "content" => "hola"}
             ]
    end

    test "tool messages no consecutivos con el mismo content NO se deduplican" do
      messages = [
        %{"role" => "tool", "content" => "same"},
        %{"role" => "tool", "content" => "same"},
        # Mensaje no-tool entremedias: rompe la consecutividad.
        %{"role" => "user", "content" => "intermedio"},
        # Vuelve a aparecer el mismo content: NO debe deduplicarse con los anteriores.
        %{"role" => "tool", "content" => "same"},
        %{"role" => "tool", "content" => "same"}
      ]

      result = PromptOptimizer.lazy_cleanup(messages)

      assert result == [
               %{"role" => "tool", "content" => "same"},
               %{"role" => "user", "content" => "intermedio"},
               %{"role" => "tool", "content" => "same"}
             ]
    end
  end

  describe "stable_prefix + lazy_cleanup" do
    test "el pipeline combinado produce el resultado esperado" do
      long = String.duplicate("a", 40_001)

      messages = [
        %{"role" => "user", "content" => "u1"},
        %{"role" => "system", "content" => "  S  "},
        %{"role" => "system", "content" => "S"},
        %{"role" => "tool", "content" => "t1"},
        %{"role" => "tool", "content" => "t1"},
        %{"role" => "user", "content" => "u2\n\n\n\n"},
        %{"role" => "user", "content" => long}
      ]

      result =
        messages
        |> PromptOptimizer.stable_prefix()
        |> PromptOptimizer.lazy_cleanup()

      expected = [
        %{"role" => "system", "content" => "S"},
        %{"role" => "user", "content" => "u1"},
        %{"role" => "tool", "content" => "t1"},
        %{"role" => "user", "content" => "u2"},
        %{"role" => "user", "content" => String.duplicate("a", 40_000) <> "\n[... truncated]"}
      ]

      assert result == expected
    end

    test "pipeline combinado sobre payload complejo: hoisting, dedup, trim, colapsado y truncado en una sola pasada" do
      long = String.duplicate("b", 40_050)

      vision_parts = [
        %{"type" => "text", "text" => "  describe la imagen  "},
        %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
      ]

      nested = %{"tool" => "fs.read", "output" => "raw\n\n\n\noutput  "}

      messages = [
        # System messages: uno duplicado con whitespace y otro genuinamente distinto.
        %{"role" => "user", "content" => "hola"},
        %{"role" => "system", "content" => "  regla  "},
        %{"role" => "system", "content" => "regla"},
        %{"role" => "system", "content" => "otra"},
        # tool messages consecutivos con mismo string content: dedup.
        %{"role" => "tool", "content" => "result A"},
        %{"role" => "tool", "content" => "result A"},
        %{"role" => "tool", "content" => "result A"},
        # tool message con content no-string (lista): pasa intacto y NO deduplica.
        %{"role" => "tool", "content" => vision_parts},
        %{"role" => "tool", "content" => vision_parts},
        # tool messages no consecutivos con mismo content: NO dedup.
        %{"role" => "tool", "content" => "X"},
        %{"role" => "assistant", "content" => "ok"},
        %{"role" => "tool", "content" => "X"},
        # String content con trim, colapsado de 3+ newlines y \n\n preservado.
        %{"role" => "user", "content" => "   texto\n\n\n\nlimpio   "},
        # Otro user con paragraph break doble preservado y single newline preservado.
        %{"role" => "user", "content" => "línea 1\nlínea 2\n\nlínea 3"},
        # Content nil: intacto.
        %{"role" => "user", "content" => nil},
        # Map content: intacto.
        %{"role" => "user", "content" => nested},
        # String content largo: truncado.
        %{"role" => "user", "content" => long}
      ]

      result =
        messages
        |> PromptOptimizer.stable_prefix()
        |> PromptOptimizer.lazy_cleanup()

      expected = [
        # Systems hoisted al frente; "regla" y "  regla  " colapsan por trim.
        %{"role" => "system", "content" => "regla"},
        %{"role" => "system", "content" => "otra"},
        # No-system preservados en orden relativo.
        %{"role" => "user", "content" => "hola"},
        # 3 tool "result A" consecutivos → 1.
        %{"role" => "tool", "content" => "result A"},
        # tool con lista (no-string) pasa intacto; el duplicado consecutivo también pasa (no dedup de no-string).
        %{"role" => "tool", "content" => vision_parts},
        %{"role" => "tool", "content" => vision_parts},
        # "X" antes y después de "assistant" no se deduplican (no consecutivos).
        %{"role" => "tool", "content" => "X"},
        %{"role" => "assistant", "content" => "ok"},
        %{"role" => "tool", "content" => "X"},
        # Trim + colapsado de 3+ newlines → exactamente 2.
        %{"role" => "user", "content" => "texto\n\nlimpio"},
        # Single y double newline preservados.
        %{"role" => "user", "content" => "línea 1\nlínea 2\n\nlínea 3"},
        # nil intacto.
        %{"role" => "user", "content" => nil},
        # Map intacto.
        %{"role" => "user", "content" => nested},
        # String truncado a 40_000 + marker.
        %{"role" => "user", "content" => String.duplicate("b", 40_000) <> "\n[... truncated]"}
      ]

      assert result == expected
    end
  end
end
