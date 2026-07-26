defmodule Tokengate.Observability.OtlpBuilder do
  @moduledoc """
  Builds OTLP/JSON (OTLP traces v1) payloads from `Tokengate.Logs.RequestLog`
  entries for export to observability destinations.

  ## Privacy

  Request logs **never** contain prompt or completion content, and neither do
  the OTLP spans built here — in any privacy mode.

  The `privacy_mode` of the destination controls only two attributes:

    * `"full"` — includes `tokengate.team_member_id` and
      `tokengate.subscription_id` attributes (still metadata; no content).
    * `"metadata_only"` — omits those two attributes entirely.

  All other attributes (model, token counts, costs, latency, status) are
  present in both modes.
  """

  alias Tokengate.Logs.RequestLog
  alias Tokengate.Observability.Destination

  @scope_name "tokengate"
  @span_name "tokengate.chat_completion"
  @span_name_stream "tokengate.chat_completion.stream"

  @type otlp_payload :: map()

  @doc """
  Builds a single-span OTLP/JSON payload from one request log.

  Returns a map conforming to the OTLP traces v1 JSON shape:

      %{
        resourceSpans: [
          %{
            resource: %{attributes: [...]},
            scopeSpans: [
              %{
                scope: %{name: "tokengate"},
                spans: [span]
              }
            ]
          }
        ]
      }
  """
  @spec build_span(RequestLog.t(), Destination.t()) :: otlp_payload()
  def build_span(request_log, destination) do
    span = build_single_span(request_log, destination)

    wrap_in_resource_spans([span])
  end

  @doc """
  Builds a batched OTLP/JSON payload from multiple request logs, grouping
  all spans into a single `scopeSpans` entry.
  """
  @spec build_payload([RequestLog.t()], Destination.t()) :: otlp_payload()
  def build_payload(request_logs, destination) do
    spans = Enum.map(request_logs, &build_single_span(&1, destination))

    wrap_in_resource_spans(spans)
  end

  # ---------------------------------------------------------------------------
  # Span construction
  # ---------------------------------------------------------------------------

  defp build_single_span(request_log, destination) do
    privacy_mode = Map.get(destination, :privacy_mode) || "metadata_only"

    %{
      traceId: trace_id(request_log),
      spanId: span_id(request_log),
      name: span_name(request_log),
      kind: 2,
      startTimeUnixNano: start_time_nano(request_log),
      endTimeUnixNano: end_time_nano(request_log),
      attributes: build_attributes(request_log, privacy_mode),
      status: build_status(request_log)
    }
  end

  defp span_name(%RequestLog{streaming: true}), do: @span_name_stream
  defp span_name(%RequestLog{}), do: @span_name

  # ---------------------------------------------------------------------------
  # Deterministic trace/span IDs (md5-based, 32/16 hex chars)
  # ---------------------------------------------------------------------------

  defp trace_id(request_log) do
    request_log
    |> log_fingerprint("trace")
    |> String.slice(0, 32)
  end

  defp span_id(request_log) do
    request_log
    |> log_fingerprint("span")
    |> String.slice(0, 16)
  end

  defp log_fingerprint(request_log, salt) do
    id = to_string(request_log.id)
    inserted_at = to_string(request_log.inserted_at)

    :crypto.hash(:md5, salt <> ":" <> id <> ":" <> inserted_at)
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Timestamps (string nanos)
  # ---------------------------------------------------------------------------

  defp start_time_nano(request_log) do
    request_log.inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:nanosecond)
    |> Integer.to_string()
  end

  defp end_time_nano(request_log) do
    latency_ms = request_log.latency_ms || 0

    request_log.inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:nanosecond)
    |> Kernel.+(latency_ms * 1_000_000)
    |> Integer.to_string()
  end

  # ---------------------------------------------------------------------------
  # Attributes (OTLP keyvalue shape)
  # ---------------------------------------------------------------------------

  defp build_attributes(request_log, privacy_mode) do
    base_attrs = [
      kv("gen_ai.request.model", request_log.model_requested),
      kv("gen_ai.response.model", request_log.model_responded),
      kv_int("gen_ai.usage.prompt_tokens", request_log.prompt_tokens),
      kv_int("gen_ai.usage.completion_tokens", request_log.completion_tokens),
      kv("gen_ai.system", "tokengate"),
      kv("tokengate.agent.type", request_log.agent_type),
      kv_double("tokengate.cost.estimated_usd", request_log.estimated_cost_usd),
      kv_double("tokengate.cost.usd", request_log.cost_usd),
      kv_double("tokengate.cost.provider_usd", request_log.provider_cost_usd),
      kv_double("tokengate.cost.savings_usd", request_log.savings_usd),
      kv_bool("tokengate.streaming", request_log.streaming),
      kv_int("http.status_code", request_log.status_code)
    ]

    maybe_add_privacy_attrs(base_attrs, privacy_mode, request_log)
  end

  defp maybe_add_privacy_attrs(attrs, "full", request_log) do
    attrs ++
      [
        kv("tokengate.team_member_id", to_string(request_log.team_member_id)),
        kv("tokengate.subscription_id", maybe_uuid_string(request_log.subscription_id))
      ]
  end

  defp maybe_add_privacy_attrs(attrs, _privacy_mode, _request_log), do: attrs

  defp maybe_uuid_string(nil), do: nil
  defp maybe_uuid_string(value), do: to_string(value)

  # ---------------------------------------------------------------------------
  # Status
  # ---------------------------------------------------------------------------

  defp build_status(%RequestLog{status_code: code})
       when is_integer(code) and code >= 200 and code < 300 do
    %{code: 1}
  end

  defp build_status(_request_log) do
    %{code: 2}
  end

  # ---------------------------------------------------------------------------
  # OTLP keyvalue helpers
  # ---------------------------------------------------------------------------

  defp kv(key, value) when is_binary(value) do
    %{key: key, value: %{stringValue: value}}
  end

  defp kv(key, nil) do
    %{key: key, value: %{stringValue: ""}}
  end

  defp kv(key, value) do
    %{key: key, value: %{stringValue: to_string(value)}}
  end

  defp kv_int(key, nil), do: %{key: key, value: %{intValue: 0}}
  defp kv_int(key, value) when is_integer(value), do: %{key: key, value: %{intValue: value}}

  defp kv_bool(key, value) when is_boolean(value), do: %{key: key, value: %{boolValue: value}}

  defp kv_double(key, nil), do: %{key: key, value: %{doubleValue: 0.0}}

  defp kv_double(key, %Decimal{} = value) do
    %{key: key, value: %{doubleValue: Decimal.to_float(value)}}
  end

  defp kv_double(key, value) when is_number(value) do
    %{key: key, value: %{doubleValue: value / 1}}
  end

  # ---------------------------------------------------------------------------
  # Resource spans wrapper
  # ---------------------------------------------------------------------------

  defp wrap_in_resource_spans(spans) do
    %{
      resourceSpans: [
        %{
          resource: %{
            attributes: [
              kv("service.name", "tokengate")
            ]
          },
          scopeSpans: [
            %{
              scope: %{name: @scope_name},
              spans: spans
            }
          ]
        }
      ]
    }
  end
end
