defmodule Tokengate.Proxy.RequestPayloadTest do
  use ExUnit.Case, async: true
  alias Tokengate.Proxy.RequestPayload

  describe "strip_nulls/1" do
    test "drops top-level keys whose value is nil" do
      # La forma que manda un SDK: los knobs que no usa van en null explícito.
      # Surplus Intelligence responde 400 por cualquiera de ellos.
      payload = %{
        "model" => "deepseek-v4.1-flash",
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "max_tokens" => nil,
        "stream" => nil,
        "temperature" => nil,
        "tools" => nil,
        "stop" => nil
      }

      assert RequestPayload.strip_nulls(payload) == %{
               "model" => "deepseek-v4.1-flash",
               "messages" => [%{"role" => "user", "content" => "hi"}]
             }
    end

    test "keeps values that are present, including false and zero" do
      payload = %{"stream" => false, "temperature" => 0, "max_tokens" => 16, "stop" => []}

      assert RequestPayload.strip_nulls(payload) == payload
    end

    test "keeps nested nulls: a tool_calls assistant turn carries content: null" do
      # Borrar esa clave cambia la forma del mensaje que un upstream estricto
      # valida, así que los nils anidados se dejan intactos a propósito.
      payload = %{
        "model" => "m",
        "messages" => [
          %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "1"}]}
        ],
        "tool_choice" => nil
      }

      assert RequestPayload.strip_nulls(payload) == %{
               "model" => "m",
               "messages" => [
                 %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "1"}]}
               ]
             }
    end

    test "a payload with no nils comes back unchanged" do
      payload = %{
        "model" => "m",
        "messages" => [],
        "stream_options" => %{"include_usage" => true}
      }

      assert RequestPayload.strip_nulls(payload) == payload
    end

    test "an empty payload stays an empty map" do
      assert RequestPayload.strip_nulls(%{}) == %{}
    end

    test "a non-map payload is returned untouched (defensive)" do
      assert RequestPayload.strip_nulls(nil) == nil
      assert RequestPayload.strip_nulls("raw bytes") == "raw bytes"
    end
  end
end
