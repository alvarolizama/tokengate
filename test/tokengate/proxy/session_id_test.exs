defmodule Tokengate.Proxy.SessionIdTest do
  @moduledoc """
  Covers SessionId.derive/2: client-provided keys win, derivation from the
  conversation opening otherwise, nil when nothing derivable.
  """
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.SessionId

  describe "derive/2 client-provided keys" do
    test "body session_id takes precedence" do
      payload = %{"session_id" => "agent-session-1", "messages" => []}
      assert SessionId.derive(payload, "header-session") == "agent-session-1"
    end

    test "x-session-id header is used when body has none" do
      payload = %{"messages" => []}
      assert SessionId.derive(payload, "header-session") == "header-session"
    end

    test "prompt_cache_key body field is used as third option" do
      payload = %{"prompt_cache_key" => "cache-key-9", "messages" => []}
      assert SessionId.derive(payload, nil) == "cache-key-9"
    end

    test "whitespace-only session_id is ignored" do
      payload = %{"session_id" => "   ", "messages" => []}
      assert SessionId.derive(payload, nil) == nil
    end

    test "over-long session_id is truncated to 256 chars" do
      long = String.duplicate("x", 400)
      assert String.length(SessionId.derive(%{"session_id" => long}, nil)) == 256
    end
  end

  describe "derive/2 derivation from messages" do
    test "same opening messages derive the same key" do
      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "Hola"}
      ]

      assert SessionId.derive(%{"messages" => messages}, nil) ==
               SessionId.derive(%{"messages" => messages}, nil)
    end

    test "different opening derives a different key" do
      m1 = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "Hola"}
      ]

      m2 = [
        %{"role" => "system", "content" => "You are a pirate."},
        %{"role" => "user", "content" => "Hola"}
      ]

      refute SessionId.derive(%{"messages" => m1}, nil) ==
               SessionId.derive(%{"messages" => m2}, nil)
    end

    test "longer conversation with same opening derives the same key" do
      opening = [
        %{"role" => "system", "content" => "Eres un asistente técnico."},
        %{"role" => "user", "content" => "Revisa este código"}
      ]

      later = opening ++ [%{"role" => "assistant", "content" => "Claro"}]

      assert SessionId.derive(%{"messages" => opening}, nil) ==
               SessionId.derive(%{"messages" => later}, nil)
    end

    test "no messages at all returns nil" do
      assert SessionId.derive(%{}, nil) == nil
      assert SessionId.derive(%{"messages" => []}, nil) == nil
    end

    test "structured content in the opener doesn't crash" do
      messages = [
        %{"role" => "system", "content" => "sys"},
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hola"}]}
      ]

      assert SessionId.derive(%{"messages" => messages}, nil) == nil
    end
  end
end
