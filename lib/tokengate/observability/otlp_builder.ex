defmodule Tokengate.Observability.OtlpBuilder do
  @moduledoc ~S"""
  Builds OTLP/JSON (OTLP traces v1) payloads from `Tokengate.Logs.RequestLog`
  entries for export to observability destinations.

  Request logs never contain prompt or completion content, and neither do
  the OTLP spans built here.

  The `service.name` resource attribute is derived from the request log's
  team member: `"#{team.name} - #{user.email}"`. When the team member
  association is not loaded, it falls back to `"tokengate"`.
  """

  alias Tokengate.Logs.RequestLog

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
  @spec build_span(RequestLog.t(), term()) :: otlp_payload()
  def build_span(request_log, _destination) do
    span = build_single_span(request_log)
    identity = build_identity(request_log)

    wrap_in_resource_spans([span], identity)
  end

  @doc """
  Builds a batched OTLP/JSON payload from multiple request logs, grouping
  all spans into a single `scopeSpans` entry.

  The `service.name` resource attribute uses the identity derived from the
  first request log in the batch. All logs in a batch are expected to belong
  to the same team.
  """
  @spec build_payload([RequestLog.t()], term()) :: otlp_payload()
  def build_payload([], _destination) do
    wrap_in_resource_spans([], "tokengate")
  end

  def build_payload([first | _] = request_logs, _destination) do
    spans = Enum.map(request_logs, &build_single_span/1)
    identity = build_identity(first)

    wrap_in_resource_spans(spans, identity)
  end

  # ---------------------------------------------------------------------------
  # Span construction
  # ---------------------------------------------------------------------------

  defp build_single_span(request_log) do
    %{
      traceId: trace_id(request_log),
      spanId: span_id(request_log),
      name: span_name(request_log),
      kind: 2,
      startTimeUnixNano: start_time_nano(request_log),
      endTimeUnixNano: end_time_nano(request_log),
      attributes: build_attributes(request_log),
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
  # Identity (service.name / api_key_name)
  # ---------------------------------------------------------------------------

  @doc ~S"""
  Builds the identity string used for `service.name` and
  `trace.metadata.openrouter.api_key_name` from the request log's team member.

  Format: `"#{team.name} - #{user.email}"`

  Falls back to `"tokengate"` when the team member association is not loaded
  or is nil.
  """
  @spec build_identity(RequestLog.t()) :: String.t()
  def build_identity(%RequestLog{team_member: %Tokengate.Accounts.TeamMember{} = tm}) do
    team = Map.get(tm, :team)
    user = Map.get(tm, :user)

    case {team, user} do
      {%Tokengate.Accounts.Team{name: team_name}, %Tokengate.Accounts.User{email: email}}
      when is_binary(team_name) and is_binary(email) ->
        "#{team_name} - #{email}"

      _ ->
        "tokengate"
    end
  end

  def build_identity(_request_log), do: "tokengate"

  # ---------------------------------------------------------------------------
  # Attributes (OTLP keyvalue shape)
  # ---------------------------------------------------------------------------

  defp build_attributes(request_log) do
    prompt_tokens = request_log.prompt_tokens || 0
    completion_tokens = request_log.completion_tokens || 0
    total_tokens = prompt_tokens + completion_tokens

    [
      kv("gen_ai.request.model", request_log.model_requested),
      kv("gen_ai.response.model", request_log.model_responded),
      kv("gen_ai.system", "tokengate"),
      kv_int("gen_ai.usage.prompt_tokens", prompt_tokens),
      kv_int("gen_ai.usage.completion_tokens", completion_tokens),
      kv_int("gen_ai.usage.total_tokens", total_tokens),
      kv_double("gen_ai.usage.cost", request_log.provider_cost_usd),
      kv("tokengate.agent.type", request_log.agent_type),
      kv("tokengate.agent.client", request_log.client_agent),
      kv_bool("tokengate.streaming", request_log.streaming),
      kv_int("http.status_code", request_log.status_code),
      kv("tokengate.team_member_id", to_string(request_log.team_member_id)),
      kv("trace.metadata.openrouter.api_key_name", build_identity(request_log))
    ]
  end

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

  defp wrap_in_resource_spans(spans, identity) do
    %{
      resourceSpans: [
        %{
          resource: %{
            attributes: [
              %{key: "service.name", value: %{stringValue: identity}}
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
