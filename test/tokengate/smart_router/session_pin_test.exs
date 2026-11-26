defmodule Tokengate.SmartRouter.SessionPinTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.SessionPin

  @pin %{
    use_case_id: "uc-1",
    use_case_key: "writing",
    use_case_model_id: "bind-1",
    model_id: "model-1",
    model_name: "m1",
    effort_tier: "high",
    requirements: %{tools: false, vision: false, structured: false}
  }

  test "a pin round-trips and expires lazily" do
    assert :ok = SessionPin.put("subject", "session", @pin, 60_000)

    assert %{model_id: "model-1"} = SessionPin.get("subject", "session")

    SessionPin.backdate_for_test("subject", "session", 61_000)
    assert SessionPin.get("subject", "session") == nil
  end

  test "a nil subject or session key is never pinned" do
    assert :ok = SessionPin.put(nil, "session", @pin, 60_000)
    assert :ok = SessionPin.put("subject", nil, @pin, 60_000)
    assert SessionPin.put("subject", "session", @pin, 0) == :ok

    assert SessionPin.get(nil, "session") == nil
    assert SessionPin.get("subject", nil) == nil
    assert SessionPin.get("subject", "session") == nil
  end

  test "clear and flush" do
    SessionPin.put("subject", "session", @pin, 60_000)
    :ok = SessionPin.clear("subject", "session")
    assert SessionPin.get("subject", "session") == nil

    SessionPin.put("subject", "session", @pin, 60_000)
    SessionPin.flush()
    assert SessionPin.get("subject", "session") == nil
  end
end
