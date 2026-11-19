defmodule TokengateWeb.Plugs.ApiAuthClientAgentTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  alias TokengateWeb.Plugs.ApiAuth

  defp conn_with(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/v1/chat/completions"), fn {k, v}, acc ->
      put_req_header(acc, k, v)
    end)
  end

  test "X-Title wins (OpenRouter app attribution)" do
    conn = conn_with([{"x-title", "Hermes Agent"}, {"user-agent", "OpenAI/Python 1.0"}])
    assert ApiAuth.client_agent(conn) == "Hermes Agent"
  end

  test "HTTP-Referer is used when no X-Title (attribution URL)" do
    conn =
      conn_with([
        {"http-referer", "https://hermes-agent.nousresearch.com"},
        {"user-agent", "OpenAI/Python 1.0"}
      ])

    assert ApiAuth.client_agent(conn) == "https://hermes-agent.nousresearch.com"
  end

  test "falls back to User-Agent then X-Agent-Type then unknown" do
    assert ApiAuth.client_agent(conn_with([{"user-agent", "opencode/2.1"}])) == "opencode/2.1"
    assert ApiAuth.client_agent(conn_with([{"x-agent-type", "hermes"}])) == "hermes"
    assert ApiAuth.client_agent(conn_with([])) == "unknown"
  end
end
