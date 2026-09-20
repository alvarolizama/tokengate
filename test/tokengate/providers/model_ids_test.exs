defmodule Tokengate.Providers.ModelIdsTest do
  @moduledoc """
  Lo que se puede afirmar de un id de modelo SIN ninguna tabla: su nombre corto,
  el lab de su prefijo y el tipo que el id sugiere.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Providers.ModelIds

  describe "hints" do
    test "short_name strips a lab prefix and keeps the last segment of a path" do
      assert ModelIds.short_name("openai/gpt-5-nano") == "gpt-5-nano"
      assert ModelIds.short_name("glm-5.2") == "glm-5.2"
      assert ModelIds.short_name("accounts/fireworks/routers/kimi-latest") == "kimi-latest"
    end

    test "lab_key only for a lab/model id" do
      assert ModelIds.lab_key("anthropic/claude-opus-4.7") == "anthropic"
      assert ModelIds.lab_key("glm-5.2") == nil
      assert ModelIds.lab_key("accounts/fireworks/routers/kimi-latest") == nil
      assert ModelIds.lab_key("@cf/meta/llama-3.1-8b-instruct") == nil
    end

    test "model_type_hint reads the id, and the operator confirms it" do
      assert ModelIds.model_type_hint("google/gemini-embedding-001") == "embedding"
      assert ModelIds.model_type_hint("openai/gpt-5-nano") == "llm"
    end
  end
end
