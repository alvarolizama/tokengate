defmodule Tokengate.AgentsTest do
  use ExUnit.Case, async: true

  doctest Tokengate.Agents

  alias Tokengate.Agents

  test "opencode major version splits v1 (0.x) from v2+" do
    assert Agents.identify("opencode/0.9.2", "unknown").label == "opencode v1"
    assert Agents.identify("opencode/1.0.0", "unknown").label == "opencode v1"
    assert Agents.identify("opencode/2.3.4", "unknown").label == "opencode v2"
  end

  test "short family names do not false-positive on substrings" do
    # "pi" must not match python / copilot / pipeline
    assert Agents.identify("python-requests/2.31", "unknown").family == "python-requests"
    assert Agents.identify("copilot/1.0", "unknown").family == "Copilot"
    assert Agents.identify("pipeline/2.0", "unknown").family == "pipeline"
    assert Agents.identify("pi/3.2", "unknown").family == "Pi"
  end

  test "explicit X-Agent-Type wins over a generic User-Agent" do
    assert Agents.identify("node", "opencode").family == "opencode"
    assert Agents.identify("axios/1.6", "hermes").family == "Hermes"
  end

  test "unknown placeholders fall back to the other signal" do
    assert Agents.identify("unknown", "claude-cli/2.0").family == "Claude Code"
    assert Agents.identify("curl/8.1", "unknown").family == "curl"
    assert Agents.identify(nil, nil).label == "unknown"
    assert Agents.identify("", "").label == "unknown"
  end

  test "grouping key carries family + major version" do
    a = Agents.identify("opencode/2.1", "unknown")
    b = Agents.identify("opencode/2.9", "unknown")
    c = Agents.identify("opencode/0.1", "unknown")
    assert a.key == b.key
    assert a.key != c.key
  end
end
