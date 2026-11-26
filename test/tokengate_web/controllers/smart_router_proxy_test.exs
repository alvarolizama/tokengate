defmodule TokengateWeb.SmartRouterProxyTest do
  @moduledoc """
  End-to-end coverage of the `"model": "router"` alias (S3).

  Real HTTP through the endpoint: the gates, the decision engine reading the
  real `router_*` tables, the ACL-bypassing route, the multi-hop fallback
  cascade, the use-case prompt policy, `effort_override` precedence and the
  honest accounting (frozen baseline, `$0` cache hits, decision cost rows).
  """

  use TokengateWeb.ConnCase, async: false

  use Oban.Testing, repo: Tokengate.Repo

  import Ecto.Query, only: [from: 2]

  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Logs.{RequestLog, WriteWorker}
  alias Tokengate.Proxy.ResponseCache
  alias Tokengate.Routing.Router
  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.{Config, UseCase, UseCaseModel}

  # ---------------------------------------------------------------------------
  # Fake upstream
  # ---------------------------------------------------------------------------

  defmodule UpstreamPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      payload = decode(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:upstream_hit, conn.path_info, payload})
        send(pid, {:upstream_inflight, Tokengate.Logs.Inflight.list()})
      end

      case conn.path_info do
        ["down" | _] ->
          json(conn, 500, %{"error" => %{"message" => "upstream down"}})

        ["chat", "completions" | _] ->
          # A `model_type: "llm"` decision model is asked for its answer as a
          # chat completion whose content is pure JSON. It shares the served
          # path, so the router's own system prompt is the discriminator.
          if classifier_prompt?(payload) do
            json(conn, 200, classifier_ok())
          else
            respond(conn, payload)
          end

        ["decisions" | _] ->
          json(conn, 200, %{
            "answers" => [
              %{
                "type" => "choice",
                "name" => "use_case",
                "choice" => :persistent_term.get({__MODULE__, :use_case_key}, "coding"),
                "confidence" => 0.92
              }
            ],
            "usage" => %{"prompt_tokens" => 1_000, "completion_tokens" => 0}
          })

        _ ->
          respond(conn, payload)
      end
    end

    defp respond(conn, payload) do
      if payload["stream"] == true do
        stream(conn)
      else
        json(conn, 200, chat_ok())
      end
    end

    defp classifier_prompt?(payload) do
      payload["messages"]
      |> List.wrap()
      |> Enum.any?(fn
        %{"role" => "system", "content" => content} when is_binary(content) ->
          String.contains?(content, "You route one request")

        _ ->
          false
      end)
    end

    # The classifier's answer in the chat wire: content is a JSON object with
    # the use case key the test pinned in `:persistent_term`.
    defp classifier_ok do
      %{
        "id" => "chatcmpl-router-decision",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" =>
                Jason.encode!(%{
                  "use_case" => :persistent_term.get({__MODULE__, :use_case_key}, "coding"),
                  "confidence" => 0.92
                })
            }
          }
        ],
        "usage" => %{
          "prompt_tokens" => 1_000,
          "completion_tokens" => 0,
          "total_tokens" => 1_000
        }
      }
    end

    defp decode(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end
    end

    defp chat_ok do
      %{
        "id" => "chatcmpl-router",
        "object" => "chat.completion",
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 10,
          "total_tokens" => 30,
          "cost" => 0.00015
        }
      }
    end

    defp stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      frames = [
        ~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30,"cost":0.00015}}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce_while(frames, conn, fn frame, conn ->
        case chunk(conn, frame) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end

  # An upstream that never answers: a listening socket that is never accepted.
  # The kernel completes the handshake, the request sits in the backlog and no
  # response ever comes, so the lane's own `receive_timeout_ms` ends the attempt
  # with a real `:timeout`. It is a dedicated port on purpose — a client-side
  # timeout leaves the response pending on the TCP connection, and a straggler
  # on a SHARED pooled connection corrupts an unrelated later request.
  #
  # No timer anywhere: the socket belongs to the test process and closes with it.
  defp black_hole_upstream do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    port
  end

  setup do
    :persistent_term.put({UpstreamPlug, :test_pid}, self())
    port = Tokengate.TestPort.free_port()
    :persistent_term.put({__MODULE__, :port}, port)
    start_supervised!({Bandit, plug: UpstreamPlug, scheme: :http, ip: :loopback, port: port})
    :ok
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  defp upstream_url(path) do
    "http://localhost:#{:persistent_term.get({__MODULE__, :port})}#{path}"
  end

  defp create_lane(name, prices \\ %{input: "1", output: "2"}, path \\ "", provider_attrs \\ %{}) do
    {:ok, provider} =
      Providers.create_provider(
        Map.merge(%{name: "P #{name}", base_url: upstream_url(path)}, provider_attrs)
      )

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-#{name}"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: name,
        model_type: "llm",
        context_window: 128_000
      })

    {:ok, model_provider} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "upstream-#{name}",
        priority: 1,
        input_cost_per_million: Decimal.new(prices.input),
        output_cost_per_million: Decimal.new(prices.output)
      })

    %{
      provider: provider,
      credential: credential,
      model: model,
      model_provider: model_provider
    }
  end

  defp member_fixture(opts \\ %{}) do
    u = unique()

    group_attrs =
      %{
        name: "Router Group #{u}",
        default_rpm_limit: 600,
        default_concurrency_limit: 10,
        router_enabled: Map.get(opts, :group_router_enabled, true)
      }
      |> then(fn attrs ->
        cond do
          Map.get(opts, :blocked) ->
            attrs

          limit = Map.get(opts, :monthly_limit_usd) ->
            Map.put(attrs, :monthly_spend_limit_usd, to_string(limit))

          true ->
            Map.put(attrs, :unlimited_spend, true)
        end
      end)

    {:ok, group} = Accounts.create_group(group_attrs)

    {:ok, user} =
      Accounts.register_user(%{
        email: "router-#{u}@example.com",
        name: "Router #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{
        user_id: user.id,
        group_id: group.id,
        router_enabled: Map.get(opts, :member_router_enabled)
      })

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{group: group, user: user, member: Repo.preload(member, :api_key), token: token}
  end

  defp enable_router(attrs \\ %{}) do
    config = Config.ensure!()

    {:ok, config} =
      config
      |> Config.changeset(Map.merge(%{enabled: true}, attrs))
      |> Repo.update()

    SmartRouter.invalidate()
    config
  end

  # One use case with the given bindings. `pin_session` is off by default here:
  # a pin would keep the SECOND request of a test on the first decision and hide
  # the routing behaviour under test.
  defp create_use_case(attrs, bindings) do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(
        Map.merge(
          %{
            key: "uc_#{unique()}",
            name: "Use case",
            pin_session: false,
            enabled: true,
            priority: 10
          },
          attrs
        )
      )
      |> Repo.insert()

    bindings =
      Enum.map(bindings, fn binding ->
        {:ok, row} =
          %UseCaseModel{}
          |> UseCaseModel.changeset(Map.merge(%{router_use_case_id: use_case.id}, binding))
          |> Repo.insert()

        row
      end)

    SmartRouter.invalidate()
    {use_case, bindings}
  end

  defp authed_conn(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp chat_body(model, extra \\ %{}) do
    Map.merge(
      %{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => "hola, ¿cómo vas?"}]
      },
      extra
    )
  end

  defp drain_logs do
    assert_enqueued(worker: WriteWorker)
    assert %{success: _} = Oban.drain_queue(queue: :logs)
  end

  defp logs_for(member) do
    Repo.all(
      from l in RequestLog, where: l.group_member_id == ^member.id, order_by: l.inserted_at
    )
  end

  ## GET /v1/models ############################################################

  test "GET /v1/models advertises the alias only when config AND subject allow it", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    %{model: model} = create_lane("listed-#{unique()}")
    {:ok, _grant} = Providers.grant_model_to_group(member.group_id, model.id)

    # Router off: the alias is not advertised even for an opted-in subject.
    config = Config.ensure!()

    conn = conn |> authed_conn(token) |> get(~p"/v1/models")
    refute "router" in model_ids(json_response(conn, 200))

    # Router on: advertised.
    {:ok, _} = Repo.update(Config.changeset(config, %{enabled: true}))
    SmartRouter.invalidate()

    conn = conn |> recycle() |> authed_conn(token) |> get(~p"/v1/models")
    assert "router" in model_ids(json_response(conn, 200))
    entry = Enum.find(json_response(conn, 200)["data"], &(&1["id"] == "router"))
    assert entry["model_type"] == "router"
    assert entry["owned_by"] == "tokengate"

    # Router on, subject opted OUT: the alias is not advertised.
    {:ok, member} = Accounts.update_group_member(member, %{router_enabled: false})
    _ = member

    conn = conn |> recycle() |> authed_conn(token) |> get(~p"/v1/models")
    refute "router" in model_ids(json_response(conn, 200))
  end

  defp model_ids(%{"data" => data}), do: Enum.map(data, & &1["id"])

  ## Non-chat surfaces #########################################################

  test "non-chat endpoints reject the alias with 400 model_type_mismatch", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    %{model: model} = create_lane("media-#{unique()}")

    {:ok, _grant} = Providers.grant_model_to_group(member.group_id, model.id)
    enable_router()

    requests = [
      {~p"/v1/embeddings", %{"model" => "router", "input" => "hola"}},
      {~p"/v1/audio/transcriptions", %{"model" => "router"}},
      {~p"/v1/audio/speech", %{"model" => "router", "voice" => "alloy", "input" => "hola"}},
      {~p"/v1/images/generations", %{"model" => "router", "prompt" => "a cat"}},
      {~p"/v1/decisions",
       %{
         "model" => "router",
         "input" => "¿a dónde va?",
         "questions" => [
           %{
             "type" => "choice",
             "name" => "route",
             "choices" => [%{"value" => "billing"}, %{"value" => "technical"}]
           }
         ]
       }}
    ]

    Enum.each(requests, fn {path, body} ->
      response = conn |> recycle() |> authed_conn(token) |> post(path, body)

      assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(response, 400),
             "expected 400 model_type_mismatch from #{path}"
    end)

    # Nothing reached a provider: the rejection is local.
    refute_receive {:upstream_hit, _, _}, 200
  end

  ## Gates ####################################################################

  test "503 router_disabled when the router is off", %{conn: conn} do
    %{token: token} = member_fixture()
    _ = Config.ensure!()

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    assert %{"error" => %{"code" => "router_disabled"}} = json_response(conn, 503)
    refute_receive {:upstream_hit, _, _}, 200
  end

  test "403 router_access_disabled when the subject opted out", %{conn: conn} do
    %{token: token} = member_fixture(%{member_router_enabled: false})
    enable_router()

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    assert %{"error" => %{"code" => "router_access_disabled"}} = json_response(conn, 403)
    refute_receive {:upstream_hit, _, _}, 200
  end

  test "503 router_no_candidates when no use case can serve", %{conn: conn} do
    %{token: token} = member_fixture()
    enable_router()

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    assert %{"error" => %{"code" => "router_no_candidates"}} = json_response(conn, 503)
  end

  test "402 before the decision when the subject has no spending path", %{conn: conn} do
    %{token: token, member: member, user: _user} = member_fixture(%{blocked: true})
    primary = create_lane("blocked-#{unique()}")
    enable_router()

    {_use_case, _} =
      create_use_case(%{}, [%{target_model_id: primary.model.id, effort_tier: "any"}])

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    assert %{"error" => %{"code" => "no_credit"}} = json_response(conn, 402)
    refute_receive {:upstream_hit, _, _}, 200
    assert Budgets.limit_spend({:user, member.user_id}) in [nil, %{consumed_micro: 0}]
  end

  ## Happy path ###############################################################

  test "routes to the decision's primary through the ACL bypass and logs honest telemetry",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture(%{monthly_limit_usd: 10})
    primary = create_lane("primary-#{unique()}")
    baseline = create_lane("baseline-#{unique()}", %{input: "3", output: "6"})

    {:ok, member} =
      Accounts.update_group_member(member, %{router_baseline_model_id: baseline.model.id})

    enable_router(%{baseline_model_id: baseline.model.id})

    {use_case, [binding]} =
      create_use_case(%{}, [
        %{target_model_id: primary.model.id, effort_tier: "high", effort_override: nil}
      ])

    # The model is NOT granted to the group: only the router's ACL bypass can
    # reach it.
    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    body = json_response(conn, 200)
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "ok"

    # The upstream received the lane's own model id, never the alias.
    assert_receive {:upstream_hit, _path, upstream_payload}
    assert upstream_payload["model"] == "upstream-#{primary.model.name}"

    drain_logs()
    [log] = logs_for(member)

    assert log.model_requested == "router"
    assert log.model_id == primary.model.id
    assert log.model_resolved == primary.model.name
    assert log.routed_via_router == true
    assert log.router_use_case_id == use_case.id
    assert log.router_use_case_key == use_case.key
    assert log.router_use_case_model_id == binding.id
    assert log.router_effort_tier == "high"
    assert log.router_decision_source in ["single_candidate", "fast_path"]
    assert is_integer(log.router_decision_ms)
    # The model is reachable ONLY through the router for this subject.
    assert log.router_direct_access == false
    # Real cost is the served one; the baseline is frozen from ITS own lane.
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
    assert log.router_baseline_model_id == baseline.model.id
    # 20 prompt * 3/1M + 10 completion * 6/1M = 0.00012
    assert Decimal.equal?(log.router_baseline_cost_usd, Decimal.new("0.00012"))
    # Real spend debited to the subject.
    assert %{consumed_micro: 150} = Budgets.limit_spend({:user, member.user_id})
  end

  test "a directly accessible model reports router_direct_access true", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("direct-#{unique()}")

    {:ok, _grant} = Providers.grant_model_to_group(member.group_id, primary.model.id)
    enable_router()
    create_use_case(%{}, [%{target_model_id: primary.model.id}])

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))
    assert json_response(conn, 200)

    drain_logs()
    [log] = logs_for(member)
    assert log.router_direct_access == true
  end

  ## Cascade ##################################################################

  test "falls back to the next destination and moves the resolved model with it",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    # The primary's lane answers 500 for every attempt.
    primary = create_lane("dead-#{unique()}", %{input: "1", output: "1"}, "/down")
    fallback = create_lane("alive-#{unique()}", %{input: "2", output: "2"})

    enable_router()

    create_use_case(%{}, [
      %{target_model_id: primary.model.id, effort_tier: "any"},
      %{target_model_id: fallback.model.id, effort_tier: "any"}
    ])

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))

    assert json_response(conn, 200)

    hits = collect_upstream_hits()

    assert length(hits) >= 2
    assert Enum.any?(hits, fn {path, _payload} -> path == ["down", "chat", "completions"] end)

    assert Enum.any?(hits, fn {_path, payload} ->
             payload["model"] == "upstream-#{fallback.model.name}"
           end)

    # Live entry moved to the serving destination before the fallback call.
    assert last_inflight_model() == fallback.model.name

    drain_logs()
    logs = logs_for(member)
    served = Enum.find(logs, &(&1.status_code == 200))

    assert served.model_id == fallback.model.id
    assert served.model_resolved == fallback.model.name
    assert served.model_requested == "router"
    assert served.router_decision_source == "fallback_error"

    # The failed attempt is booked as its own row, still a router request.
    failed = Enum.find(logs, &(&1.model_resolved == primary.model.name))
    assert failed.provider_status_code == 500
    assert failed.model_requested == "router"
    assert failed.model_resolved == primary.model.name
    # A failed attempt never re-books the classifier: the decision cost lives on
    # the served row (and on the `router_decision` row), exactly once.
    assert failed.router_decision_cost_usd == nil
  end

  test "a timeout hop reports fallback_timeout on the row AND in the live in-flight entry",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture(%{monthly_limit_usd: 10})
    # The primary never answers and its lane gives up after 150ms: the adapter
    # reports `:timeout`, which is the reason the hop must carry.
    slow_port = black_hole_upstream()

    slow =
      create_lane("slow-#{unique()}", %{input: "1", output: "1"}, "", %{
        base_url: "http://localhost:#{slow_port}",
        receive_timeout_ms: 150
      })

    alive = create_lane("timeout-fallback-#{unique()}", %{input: "2", output: "2"})
    unused = create_lane("timeout-unused-#{unique()}", %{input: "3", output: "3"})
    decision = create_lane("timeout-decider-#{unique()}", %{input: "5", output: "5"})

    :persistent_term.put({UpstreamPlug, :use_case_key}, "uc_slow")

    # Two viable use cases force the classifier (the decision cost is then real
    # and must appear exactly once); `uc_slow` keeps its fallback inside the
    # SAME use case so the second destination is deterministic.
    create_use_case(%{key: "uc_slow", priority: 1}, [
      %{target_model_id: slow.model.id, effort_tier: "any"},
      %{target_model_id: alive.model.id, effort_tier: "any"}
    ])

    create_use_case(%{key: "uc_other", priority: 50}, [%{target_model_id: unused.model.id}])

    enable_router(%{
      decision_model_id: decision.model.id,
      charge_decision_to_subject: true,
      fast_path_max_tokens: 0
    })

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))
    assert json_response(conn, 200)

    drain_logs()
    logs = logs_for(member)
    served = Enum.find(logs, &(&1.status_code == 200 and &1.request_type == "chat"))
    decision_row = Enum.find(logs, &(&1.request_type == "router_decision"))

    assert served.model_resolved == alive.model.name
    # The hop was a timeout, not a generic error: the reason travels with it.
    assert served.router_decision_source == "fallback_timeout"
    # The decision cost is booked ONCE, on the served row and on its own row —
    # never on the failed attempt.
    assert Decimal.equal?(served.router_decision_cost_usd, Decimal.new("0.005000"))
    assert decision_row.routed_via_router == false

    if failed = Enum.find(logs, &(&1.model_resolved == slow.model.name)) do
      assert failed.router_decision_cost_usd == nil
    end

    # The live in-flight entry already showed the hop — new model AND the reason
    # — while the request was still running.
    assert %{model_resolved: model, router_decision_source: source} =
             last_inflight_entry(member)

    assert model == alive.model.name
    assert source == "fallback_timeout"
  end

  defp collect_upstream_hits(acc \\ []) do
    receive do
      {:upstream_hit, path, payload} -> collect_upstream_hits([{path, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp last_inflight_model do
    entries = collect_inflight_snapshots([])
    entries |> List.last() |> Enum.find_value(& &1.model_resolved)
  end

  # The live entry of THIS subject in the last in-flight snapshot the upstream
  # saw: what the monitor was showing when the winning attempt started.
  defp last_inflight_entry(member) do
    entries = collect_inflight_snapshots([]) |> List.last() |> List.wrap()

    Enum.find(entries, &(&1[:group_member_id] == member.id and &1[:routed_via_router] == true)) ||
      List.first(entries)
  end

  defp collect_inflight_snapshots(acc) do
    receive do
      {:upstream_inflight, entries} -> collect_inflight_snapshots([entries | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "never serves another subject's exclusive lane, even with the model ACL bypassed",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    %{token: _other_token, member: other} = member_fixture()

    global = create_lane("global-#{unique()}", %{input: "5", output: "5"})
    foreign = create_lane("foreign-#{unique()}", %{input: "0.01", output: "0.01"})

    # A cheap lane exclusive to a DIFFERENT group: it must never be selected,
    # not even though the router bypasses the model ACL.
    {:ok, _exclusive} =
      Providers.create_model_provider(%{
        model_id: global.model.id,
        credential_id: foreign.credential.id,
        provider_model: "upstream-exclusive",
        priority: 1,
        exclusive_to_group_id: other.group_id,
        input_cost_per_million: Decimal.new("0.01"),
        output_cost_per_million: Decimal.new("0.01")
      })

    enable_router()
    create_use_case(%{}, [%{target_model_id: global.model.id}])

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))
    assert json_response(conn, 200)

    drain_logs()
    [log] = logs_for(member)
    assert log.credential_id == global.credential.id
    refute log.credential_id == foreign.credential.id

    # The router door itself: the ACL bypass stops at the model, never at the
    # credential. Routing the SAME model picks this subject's lane...
    assert {:ok, route} = Router.route_by_model_id(global.model.id, member)
    assert route.credential.id == global.credential.id

    # ...and a model whose only lane belongs to another group is unroutable
    # for this subject instead of leaking that lane.
    {:ok, locked} = Providers.create_model(%{name: "locked-#{unique()}", context_window: 128_000})

    {:ok, _exclusive} =
      Providers.create_model_provider(%{
        model_id: locked.id,
        credential_id: foreign.credential.id,
        provider_model: "upstream-locked",
        priority: 1,
        exclusive_to_group_id: other.group_id
      })

    assert {:error, reason} = Router.route_by_model_id(locked.id, member)
    assert reason in [:no_available_provider, :no_providers_configured]
  end

  ## Prompt policy ############################################################

  test "applies the use-case history window and reports the measured saving", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("window-#{unique()}")

    enable_router()
    create_use_case(%{max_history_turns: 1}, [%{target_model_id: primary.model.id}])

    messages = [
      %{"role" => "user", "content" => "turno uno"},
      %{"role" => "assistant", "content" => "respuesta uno"},
      %{"role" => "user", "content" => "turno dos"},
      %{"role" => "assistant", "content" => "respuesta dos"},
      %{"role" => "user", "content" => "turno tres"}
    ]

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("router", %{"messages" => messages}))

    assert json_response(conn, 200)

    assert_receive {:upstream_hit, _path, upstream_payload}
    contents = Enum.map(upstream_payload["messages"], & &1["content"])
    assert "turno uno" not in contents
    assert "turno tres" in contents

    drain_logs()
    [log] = logs_for(member)
    assert log.prompt_tokens_saved_est > 0
  end

  test "the use-case binding enforces effort_override over the client's knobs", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("effort-#{unique()}")

    enable_router()

    create_use_case(%{}, [
      %{target_model_id: primary.model.id, effort_tier: "high", effort_override: "high"}
    ])

    body = chat_body("router", %{"reasoning_effort" => "low"})
    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
    assert json_response(conn, 200)

    assert_receive {:upstream_hit, _path, upstream_payload}
    assert upstream_payload["reasoning_effort"] == "high"

    drain_logs()
    [log] = logs_for(member)
    assert log.effort_applied == "high"
  end

  ## Cache hit ################################################################

  test "a ResponseCache hit stays a router row with no baseline", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("cache-#{unique()}")
    baseline = create_lane("cache-baseline-#{unique()}")

    enable_router(%{baseline_model_id: baseline.model.id})
    create_use_case(%{}, [%{target_model_id: primary.model.id}])

    body = chat_body("router")

    first = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
    assert json_response(first, 200)
    # The store is a cast: sync so the second request cannot overtake it.
    _ = :sys.get_state(ResponseCache)

    second = conn |> recycle() |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
    assert json_response(second, 200)
    assert get_resp_header(second, "x-tokengate-cache") == ["hit"]

    drain_logs()
    hit = Enum.find(logs_for(member), & &1.cache_hit)

    assert hit.model_requested == "router"
    assert hit.model_resolved == primary.model.name
    assert hit.routed_via_router == true
    assert hit.router_use_case_key != nil
    # $0 served locally: the counterfactual is NOT priced (F9).
    assert hit.router_baseline_cost_usd == nil
    assert Decimal.equal?(hit.provider_cost_usd, Decimal.new(0))
  end

  ## Streaming ################################################################

  test "streaming keeps the router metadata on the row", %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("stream-#{unique()}")

    enable_router()
    create_use_case(%{}, [%{target_model_id: primary.model.id}])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("router", %{"stream" => true}))

    assert response(conn, 200) =~ "[DONE]"

    drain_logs()
    [log] = logs_for(member)
    assert log.streaming == true
    assert log.model_requested == "router"
    assert log.model_id == primary.model.id
    assert log.routed_via_router == true
    assert log.router_use_case_key != nil
  end

  ## Decision cost ############################################################

  test "the classifier's own cost is booked as a separate router_decision row",
       %{conn: conn} do
    # Funded by a TOP-UP (limit exhausted): the rows must name the top-up they
    # debit so the durable reconciliation matches them.
    %{token: token, member: member} = member_fixture(%{monthly_limit_usd: 0})

    {:ok, topup} =
      Tokengate.Credits.Topups.create(%{"user_id" => member.user_id, "amount_usd" => "50.00"})

    primary = create_lane("decided-#{unique()}", %{input: "10", output: "10"})
    alt = create_lane("alternative-#{unique()}", %{input: "20", output: "20"})
    decision = create_lane("decider-#{unique()}", %{input: "5", output: "5"})

    :persistent_term.put({UpstreamPlug, :use_case_key}, "uc_a")

    {use_case_a, _} = create_use_case(%{key: "uc_a"}, [%{target_model_id: primary.model.id}])
    create_use_case(%{key: "uc_b", priority: 50}, [%{target_model_id: alt.model.id}])

    enable_router(%{
      decision_model_id: decision.model.id,
      charge_decision_to_subject: true,
      # The classifier only runs when a deterministic layer did not answer
      # first; a tiny prompt would take the fast path.
      fast_path_max_tokens: 0
    })

    _ = use_case_a

    conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body("router"))
    assert json_response(conn, 200)

    drain_logs()
    logs = logs_for(member)

    chat = Enum.find(logs, &(&1.request_type == "chat"))
    decision_row = Enum.find(logs, &(&1.request_type == "router_decision"))

    assert chat.model_id == primary.model.id
    assert chat.model_requested == "router"
    assert chat.router_decision_source in ["classifier", "decision_cache"]
    # 1000 prompt * 5/1M = 0.005
    assert Decimal.equal?(chat.router_decision_cost_usd, Decimal.new("0.005000"))

    assert decision_row.model_id == decision.model.id
    assert decision_row.model_requested == "router"
    assert Decimal.equal?(decision_row.provider_cost_usd, Decimal.new("0.005000"))
    # The decision row is the router's OWN spend, not a request it routed: it
    # never claims `routed_via_router`, never repeats the decision cost on the
    # column (that would multiply it in every SUM), has no session of its own
    # and names the SAME top-up the served request debited, so the durable
    # reconciliation matches both rows against one debit.
    assert decision_row.routed_via_router == false
    assert decision_row.router_decision_cost_usd == nil
    assert decision_row.session_id == nil
    assert decision_row.credit_topup_id == topup.id
    assert decision_row.credit_topup_id == chat.credit_topup_id

    # Both debits land on the SAME top-up (main 150 micro + decision 5000 micro),
    # and each row names it.
    assert %{consumed_micro: 5150} = Budgets.topup_spend(topup.id)
  end

  ## Decision cache ###########################################################

  test "a DecisionCache hit charges nothing and inserts no router_decision row",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture(%{monthly_limit_usd: 10})
    primary = create_lane("cached-decision-#{unique()}", %{input: "10", output: "10"})
    alt = create_lane("cached-alt-#{unique()}", %{input: "20", output: "20"})
    decision = create_lane("cached-decider-#{unique()}", %{input: "5", output: "5"})

    :persistent_term.put({UpstreamPlug, :use_case_key}, "uc_cache")

    create_use_case(%{key: "uc_cache"}, [%{target_model_id: primary.model.id}])
    create_use_case(%{key: "uc_cache_b", priority: 50}, [%{target_model_id: alt.model.id}])

    enable_router(%{
      decision_model_id: decision.model.id,
      charge_decision_to_subject: true,
      fast_path_max_tokens: 0
    })

    body = chat_body("router")

    # First request: the classifier really runs (and is billed once).
    first = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
    assert json_response(first, 200)

    # Second request, SAME conversation fingerprint → DecisionCache hit. It is
    # streamed so the gateway response cache cannot answer it instead (that
    # path never reaches the decision at all).
    second =
      conn
      |> recycle()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(body, "stream", true))

    assert response(second, 200) =~ "[DONE]"

    drain_logs()
    logs = logs_for(member)
    chats = Enum.filter(logs, &(&1.request_type == "chat"))
    decision_rows = Enum.filter(logs, &(&1.request_type == "router_decision"))

    assert length(chats) == 2
    sources = Enum.map(chats, & &1.router_decision_source)
    assert "classifier" in sources
    assert "decision_cache" in sources

    cached = Enum.find(chats, &(&1.router_decision_source == "decision_cache"))
    # The cached answer carries the ORIGINAL classifier usage: re-billing it
    # would charge the same tokens once per cache hit.
    assert cached.router_decision_cost_usd == nil

    fresh = Enum.find(chats, &(&1.router_decision_source == "classifier"))
    assert Decimal.equal?(fresh.router_decision_cost_usd, Decimal.new("0.005000"))

    # Exactly ONE decision row for the two requests: the hit books nothing.
    assert length(decision_rows) == 1
    assert %{consumed_micro: 5300} = Budgets.limit_spend({:user, member.user_id})
  end

  ## Pinned sessions ##########################################################

  test "a pinned session keeps its stale tool output and still reports compact-JSON savings",
       %{conn: conn} do
    %{token: token, member: member} = member_fixture()
    primary = create_lane("pinned-#{unique()}")

    enable_router()

    # `pin_session` keeps the conversation on the first decision; the trim
    # threshold is high on purpose so the trim's saving sits BELOW it.
    # The conversation carries tool calls, so the destination must declare
    # `supports_tools` to be viable at all.
    create_use_case(
      %{pin_session: true, compact_json: true, stale_tool_trim_threshold_pct: 90},
      [%{target_model_id: primary.model.id, supports_tools: true}]
    )

    # A big system prompt so the trim (≈800 chars) is a small fraction of the
    # whole prompt: below the 90% gate.
    huge_system = String.duplicate("reglas del sistema ", 250)

    old_tool_output = String.duplicate("salida vieja de la herramienta ", 30)

    # The JSON that travels as a STRING: `compact_json_tools` drops the padding
    # and the null keys, and the estimator must count those bytes.
    padded_arguments =
      ~s({"path": "lib/app.ex",  "count": 3,  "meta": null,  "flags": [1, 2, 3],  "note": "x"})

    messages = [
      %{"role" => "system", "content" => huge_system},
      %{"role" => "user", "content" => "abre el archivo"},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => padded_arguments}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "call_1", "content" => old_tool_output},
      %{"role" => "user", "content" => "sigue"},
      %{"role" => "assistant", "content" => "hecho"},
      %{"role" => "tool", "tool_call_id" => "call_2", "content" => "ok 2"},
      %{"role" => "user", "content" => "sigue dos"},
      %{"role" => "assistant", "content" => "hecho"},
      %{"role" => "tool", "tool_call_id" => "call_3", "content" => "ok 3"},
      %{"role" => "user", "content" => "última"},
      %{"role" => "assistant", "content" => "listo"}
    ]

    session = "pinned-session-#{unique()}"

    body = chat_body("router", %{"messages" => messages})

    # 1) No pin yet: the trim is allowed to run (nothing to protect).
    first =
      conn
      |> authed_conn(token)
      |> put_req_header("x-session-id", session)
      |> post(~p"/v1/chat/completions", body)

    assert json_response(first, 200)

    assert_receive {:upstream_hit, _path, unpinned_payload}
    unpinned_tool = Enum.find(unpinned_payload["messages"], &(&1["role"] == "tool"))
    assert unpinned_tool["content"] =~ "omitted"

    # 2) Same session AND same subject → the SessionPin answers, `pinned: true`.
    second =
      conn
      |> recycle()
      |> authed_conn(token)
      |> put_req_header("x-session-id", session)
      |> post(~p"/v1/chat/completions", body)

    assert json_response(second, 200)

    assert_receive {:upstream_hit, _path, pinned_payload}
    pinned_tool = Enum.find(pinned_payload["messages"], &(&1["role"] == "tool"))
    # The pinned session's prefix stays byte-identical: no trim below the gate.
    # (`lazy_cleanup` trimmed the edges before the policy ran, so compare
    # against the same normalized text.)
    assert pinned_tool["content"] == String.trim(old_tool_output)

    # The compact-JSON pass still ran: the arguments string lost its padding and
    # the null-valued key.
    [assistant] =
      Enum.filter(pinned_payload["messages"], &(&1["role"] == "assistant" and &1["tool_calls"]))

    [call] = assistant["tool_calls"]

    # Whitespace gone and the null-valued key dropped; key ORDER is Jason's
    # (sorted), so compare the decoded document.
    assert Jason.decode!(call["function"]["arguments"]) == %{
             "path" => "lib/app.ex",
             "count" => 3,
             "flags" => [1, 2, 3],
             "note" => "x"
           }

    drain_logs()
    pinned_logs = logs_for(member)
    pinned_row = Enum.find(pinned_logs, &(&1.router_decision_source == "session_pin"))
    assert pinned_row, "expected the second request to be served by the session pin"
    # The saving is measured on what the passes really removed — the tool-call
    # JSON included, which the plain message estimator ignores.
    assert pinned_row.prompt_tokens_saved_est > 0
  end
end
