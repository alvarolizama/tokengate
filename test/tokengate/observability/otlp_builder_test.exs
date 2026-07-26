defmodule Tokengate.Observability.OtlpBuilderTest do
  @moduledoc """
  Tests for `Tokengate.Observability.OtlpBuilder` — OTLP/JSON span shape,
  attribute values, deterministic IDs, nano timestamps, streaming names,
  status codes, privacy modes, and batch payloads.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.Destination
  alias Tokengate.Observability.OtlpBuilder

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp destination(attrs \\ %{}) do
    struct(
      %Destination{
        id: "dest-1",
        organization_id: "org-1",
        name: "OTLP Collector",
        type: "otlp_webhook",
        url: "https://collector.example.com",
        headers: %{},
        privacy_mode: "metadata_only"
      },
      attrs
    )
  end

  defp request_log(attrs \\ %{}) do
    struct(
      %RequestLog{
        id: "01HXY000000000000000000001",
        inserted_at: ~U[2026-01-15 12:00:00Z],
        team_member_id: "tm-1",
        provider_id: "prov-1",
        model_alias_id: "alias-1",
        subscription_id: "sub-1",
        model_requested: "gpt-4o",
        model_responded: "gpt-4o-2024-08-06",
        agent_type: "assistant",
        status_code: 200,
        prompt_tokens: 150,
        completion_tokens: 75,
        cost_usd: Decimal.new("0.01234"),
        provider_cost_usd: Decimal.new("0.01000"),
        savings_usd: Decimal.new("0.00234"),
        estimated_cost_usd: Decimal.new("0.01500"),
        latency_ms: 500,
        streaming: false
      },
      attrs
    )
  end

  # ---------------------------------------------------------------------------
  # Span shape
  # ---------------------------------------------------------------------------

  describe "build_span/2 — shape" do
    test "returns required OTLP top-level keys" do
      payload = OtlpBuilder.build_span(request_log(), destination())

      assert Map.has_key?(payload, :resourceSpans)
      assert is_list(payload.resourceSpans)
      assert length(payload.resourceSpans) == 1
    end

    test "resource has attributes and scopeSpans" do
      payload = OtlpBuilder.build_span(request_log(), destination())
      rs = hd(payload.resourceSpans)

      assert Map.has_key?(rs, :resource)
      assert Map.has_key?(rs.resource, :attributes)
      assert is_list(rs.resource.attributes)

      assert Map.has_key?(rs, :scopeSpans)
      assert length(rs.scopeSpans) == 1
    end

    test "scope has name 'tokengate' and spans list" do
      payload = OtlpBuilder.build_span(request_log(), destination())
      ss = hd(hd(payload.resourceSpans).scopeSpans)

      assert ss.scope.name == "tokengate"
      assert is_list(ss.spans)
      assert length(ss.spans) == 1
    end

    test "span has all required OTLP span fields" do
      payload = OtlpBuilder.build_span(request_log(), destination())
      span = hd(hd(hd(payload.resourceSpans).scopeSpans).spans)

      for key <- [
            :traceId,
            :spanId,
            :name,
            :kind,
            :startTimeUnixNano,
            :endTimeUnixNano,
            :attributes,
            :status
          ] do
        assert Map.has_key?(span, key), "missing span field: #{key}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Attribute values
  # ---------------------------------------------------------------------------

  describe "build_span/2 — attributes" do
    test "gen_ai.request.model from model_requested" do
      span = single_span()
      attr = find_attr(span, "gen_ai.request.model")
      assert attr.value.stringValue == "gpt-4o"
    end

    test "gen_ai.response.model from model_responded" do
      span = single_span()
      attr = find_attr(span, "gen_ai.response.model")
      assert attr.value.stringValue == "gpt-4o-2024-08-06"
    end

    test "token usage as intValue" do
      span = single_span()

      assert find_attr(span, "gen_ai.usage.prompt_tokens").value.intValue == 150
      assert find_attr(span, "gen_ai.usage.completion_tokens").value.intValue == 75
    end

    test "gen_ai.system is 'tokengate'" do
      span = single_span()
      assert find_attr(span, "gen_ai.system").value.stringValue == "tokengate"
    end

    test "agent type" do
      span = single_span()
      assert find_attr(span, "tokengate.agent.type").value.stringValue == "assistant"
    end

    test "cost attributes as doubleValue from Decimals" do
      span = single_span()

      assert find_attr(span, "tokengate.cost.estimated_usd").value.doubleValue == 0.015
      assert find_attr(span, "tokengate.cost.usd").value.doubleValue == 0.01234
      assert find_attr(span, "tokengate.cost.provider_usd").value.doubleValue == 0.01
      assert find_attr(span, "tokengate.cost.savings_usd").value.doubleValue == 0.00234
    end

    test "streaming as boolValue" do
      span = single_span()
      assert find_attr(span, "tokengate.streaming").value.boolValue == false
    end

    test "http.status_code as intValue" do
      span = single_span()
      assert find_attr(span, "http.status_code").value.intValue == 200
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic IDs
  # ---------------------------------------------------------------------------

  describe "build_span/2 — deterministic ids" do
    test "same log → same traceId and spanId" do
      log = request_log()
      span1 = single_span(log)
      span2 = single_span(log)

      assert span1.traceId == span2.traceId
      assert span1.spanId == span2.spanId
    end

    test "different logs → different traceId and spanId" do
      span1 = single_span(request_log(id: "01HXY000000000000000000001"))
      span2 = single_span(request_log(id: "01HXY000000000000000000002"))

      refute span1.traceId == span2.traceId
      refute span1.spanId == span2.spanId
    end

    test "traceId is 32 hex chars" do
      span = single_span()
      assert byte_size(span.traceId) == 32
      assert String.match?(span.traceId, ~r/^[0-9a-f]{32}$/)
    end

    test "spanId is 16 hex chars" do
      span = single_span()
      assert byte_size(span.spanId) == 16
      assert String.match?(span.spanId, ~r/^[0-9a-f]{16}$/)
    end
  end

  # ---------------------------------------------------------------------------
  # Nano timestamps
  # ---------------------------------------------------------------------------

  describe "build_span/2 — timestamps" do
    test "startTimeUnixNano is a string of nanos from inserted_at" do
      log = request_log(inserted_at: ~U[2026-01-15 12:00:00Z])
      span = single_span(log)

      expected_nano = DateTime.to_unix(~U[2026-01-15 12:00:00Z], :nanosecond)
      assert span.startTimeUnixNano == Integer.to_string(expected_nano)
    end

    test "endTimeUnixNano = start + latency_ms in nanos" do
      log = request_log(inserted_at: ~U[2026-01-15 12:00:00Z], latency_ms: 500)
      span = single_span(log)

      start_nano = DateTime.to_unix(~U[2026-01-15 12:00:00Z], :nanosecond)
      expected_end = start_nano + 500 * 1_000_000
      assert span.endTimeUnixNano == Integer.to_string(expected_end)
    end

    test "nil latency defaults to 0 (end == start)" do
      log = request_log(latency_ms: nil)
      span = single_span(log)

      assert span.startTimeUnixNano == span.endTimeUnixNano
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming span name
  # ---------------------------------------------------------------------------

  describe "build_span/2 — span name" do
    test "non-streaming → 'tokengate.chat_completion'" do
      span = single_span(request_log(streaming: false))
      assert span.name == "tokengate.chat_completion"
    end

    test "streaming → 'tokengate.chat_completion.stream'" do
      span = single_span(request_log(streaming: true))
      assert span.name == "tokengate.chat_completion.stream"
    end
  end

  # ---------------------------------------------------------------------------
  # Status codes
  # ---------------------------------------------------------------------------

  describe "build_span/2 — status" do
    test "2xx → STATUS_CODE_OK (code: 1)" do
      for code <- [200, 201, 204, 299] do
        span = single_span(request_log(status_code: code))
        assert span.status.code == 1
      end
    end

    test "non-2xx → STATUS_CODE_ERROR (code: 2)" do
      for code <- [400, 401, 403, 404, 429, 500, 502, 503] do
        span = single_span(request_log(status_code: code))
        assert span.status.code == 2
      end
    end

    test "nil status_code → error" do
      span = single_span(request_log(status_code: nil))
      assert span.status.code == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Privacy modes
  # ---------------------------------------------------------------------------

  describe "build_span/2 — privacy modes" do
    test "metadata_only omits team_member_id and subscription_id" do
      span = single_span(request_log(), destination(privacy_mode: "metadata_only"))

      assert find_attr(span, "tokengate.team_member_id") == nil
      assert find_attr(span, "tokengate.subscription_id") == nil
    end

    test "full includes team_member_id and subscription_id" do
      span = single_span(request_log(), destination(privacy_mode: "full"))

      tm_attr = find_attr(span, "tokengate.team_member_id")
      sub_attr = find_attr(span, "tokengate.subscription_id")

      assert tm_attr != nil
      assert tm_attr.value.stringValue == "tm-1"
      assert sub_attr != nil
      assert sub_attr.value.stringValue == "sub-1"
    end

    test "full mode does NOT add any content — same attr count + 2" do
      span_meta = single_span(request_log(), destination(privacy_mode: "metadata_only"))
      span_full = single_span(request_log(), destination(privacy_mode: "full"))

      assert length(span_full.attributes) == length(span_meta.attributes) + 2
    end
  end

  # ---------------------------------------------------------------------------
  # Batch payload
  # ---------------------------------------------------------------------------

  describe "build_payload/2 — batch" do
    test "groups multiple logs into one scopeSpans with multiple spans" do
      logs = [
        request_log(id: "01HXY000000000000000000001"),
        request_log(id: "01HXY000000000000000000002"),
        request_log(id: "01HXY000000000000000000003")
      ]

      payload = OtlpBuilder.build_payload(logs, destination())

      spans = hd(hd(payload.resourceSpans).scopeSpans).spans
      assert length(spans) == 3
    end

    test "single log in batch still works" do
      payload = OtlpBuilder.build_payload([request_log()], destination())
      spans = hd(hd(payload.resourceSpans).scopeSpans).spans
      assert length(spans) == 1
    end

    test "empty log list produces empty spans" do
      payload = OtlpBuilder.build_payload([], destination())
      spans = hd(hd(payload.resourceSpans).scopeSpans).spans
      assert spans == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp single_span(log \\ request_log(), dest \\ destination()) do
    payload = OtlpBuilder.build_span(log, dest)
    hd(hd(hd(payload.resourceSpans).scopeSpans).spans)
  end

  defp find_attr(span, key) do
    Enum.find(span.attributes, fn attr -> attr.key == key end)
  end
end
