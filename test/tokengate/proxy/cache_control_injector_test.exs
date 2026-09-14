defmodule Tokengate.Proxy.CacheControlInjectorTest do
  @moduledoc """
  Covers CacheControlInjector.inject/2: breakpoint on the last system
  message, no-ops when disabled / absent / already marked.
  """
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.CacheControlInjector

  @system %{"role" => "system", "content" => "Eres un asistente. "}
  @user %{"role" => "user", "content" => "Hola"}

  test "disabled returns payload unchanged" do
    payload = %{"messages" => [@system, @user]}
    assert CacheControlInjector.inject(payload, false) == payload
  end

  test "injects breakpoint on the last system message" do
    payload = %{"messages" => [@system, @user]}

    result = CacheControlInjector.inject(payload, true)

    [sys, _user] = result["messages"]
    assert [%{"type" => "text", "cache_control" => %{"type" => "ephemeral"}}] = sys["content"]
    # The original text survives inside the part
    assert [%{"text" => text}] = sys["content"]
    assert String.trim(text) != ""
  end

  test "prefers the LAST system message when several exist" do
    sys_a = %{"role" => "system", "content" => "primero"}
    sys_b = %{"role" => "system", "content" => "segundo"}

    result = CacheControlInjector.inject(%{"messages" => [sys_a, sys_b, @user]}, true)

    [a, b, _] = result["messages"]
    assert is_binary(a["content"])
    assert [%{"cache_control" => _}] = b["content"]
  end

  test "no system message leaves payload unchanged" do
    payload = %{"messages" => [@user]}
    assert CacheControlInjector.inject(payload, true) == payload
  end

  test "client-managed breakpoints are left untouched" do
    marked = %{
      "role" => "system",
      "content" => [
        %{"type" => "text", "text" => "sys", "cache_control" => %{"type" => "ephemeral"}}
      ]
    }

    payload = %{"messages" => [marked, @user]}
    assert CacheControlInjector.inject(payload, true) == payload
  end

  test "empty messages list is a no-op" do
    payload = %{"messages" => []}
    assert CacheControlInjector.inject(payload, true) == payload
  end
end
