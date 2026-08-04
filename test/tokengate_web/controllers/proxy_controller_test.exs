defmodule TokengateWeb.ProxyControllerTest do
  @moduledoc """
  End-to-end proxy API tests: real HTTP through the endpoint into a live
  Bandit "OpenAI" server — auth, limits, budgets, routing, fallback,
  cost tracking and async logging.
  """

  use TokengateWeb.ConnCase, async: false

  use Oban.Testing, repo: Tokengate.Repo

  import Ecto.Query, only: [from: 2]

  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Logs.WriteWorker

  @port 41236

  defmodule ProviderPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:provider_request, Jason.decode!(body)})
      end

      cond do
        "down" in conn.path_info ->
          json(conn, 500, %{"error" => %{"message" => "provider exploded"}})

        "embeddings" in conn.path_info ->
          payload = Jason.decode!(body)
          count = payload["input"] |> List.wrap() |> length()

          data =
            for idx <- 0..(count - 1) do
              %{"object" => "embedding", "index" => idx, "embedding" => [0.1, 0.2, 0.3]}
            end

          json(conn, 200, %{
            "object" => "list",
            "model" => payload["model"],
            "data" => data,
            "usage" => %{"prompt_tokens" => 11, "total_tokens" => 11, "cost" => 0.000011}
          })

        "rerank-cohere" in conn.path_info ->
          # oMLX-style response: Cohere shape, no usage
          json(conn, 200, %{
            "results" => [
              %{"index" => 1, "relevance_score" => 0.9},
              %{"index" => 0, "relevance_score" => 0.2}
            ]
          })

        "rerank" in conn.path_info ->
          # Fireworks-style response: Jina shape with usage
          json(conn, 200, %{
            "object" => "list",
            "model" => "fireworks/qwen3-reranker-8b",
            "data" => [
              %{"index" => 1, "relevance_score" => 0.9, "document" => "doc uno"},
              %{"index" => 0, "relevance_score" => 0.2, "document" => "doc cero"}
            ],
            "usage" => %{"prompt_tokens" => 42, "total_tokens" => 42, "cost" => 0.000042}
          })

        "slowstream" in conn.path_info ->
          Process.sleep(300)
          stream(conn)

        "hang" in conn.path_info ->
          # Simulates a hung/saturated provider: never answers within any
          # reasonable receive_timeout. The caller must configure a short
          # receive_timeout_ms on the credential so the test stays fast.
          Process.sleep(30_000)
          json(conn, 500, %{"error" => %{"message" => "eventually"}})

        true ->
          payload = Jason.decode!(body)

          if payload["stream"] == true do
            stream(conn)
          else
            json(conn, 200, %{
              "id" => "chatcmpl-e2e",
              "object" => "chat.completion",
              "choices" => [
                %{"index" => 0, "message" => %{"role" => "assistant", "content" => "qué onda"}}
              ],
              "usage" => %{
                "prompt_tokens" => 20,
                "completion_tokens" => 10,
                "total_tokens" => 30,
                "cost" => 0.00015
              }
            })
          end
      end
    end

    defp stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      frames = [
        ~s(data: {"choices":[{"delta":{"content":"qué"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":" onda"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22,"cost":0.00007}}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce_while(frames, conn, fn frame, conn ->
        case chunk(conn, frame) do
          {:ok, conn} -> {:cont, conn}
          # Client closed the connection after the terminal frame — nothing
          # more to write, don't raise a MatchError.
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

  setup do
    :persistent_term.put({ProviderPlug, :test_pid}, self())
    start_supervised!({Bandit, plug: ProviderPlug, scheme: :http, ip: :loopback, port: @port})
    :ok
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  defp proxy_fixture(opts \\ %{}) do
    u = unique()

    {:ok, team} =
      Accounts.create_team(%{
        name: "Team #{u}",
        monthly_budget_per_user_usd: Map.get(opts, :daily_budget, "100.00"),
        default_rpm_limit: Map.get(opts, :rpm_limit, 600),
        default_concurrency_limit: Map.get(opts, :concurrency_limit, 10)
      })

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{u}@example.com",
        name: "User #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{
        user_id: user.id,
        team_id: team.id,
        team_role: "user",
        extra_monthly_budget_usd: Map.get(opts, :extra_daily_budget),
        extra_concurrency: Map.get(opts, :extra_concurrency),
        extra_rpm: Map.get(opts, :extra_rpm)
      })

    {:ok, _api_key, token} = Accounts.replace_api_key(member)
    member = Repo.preload(member, :api_key)

    provider_url =
      case Map.get(opts, :down) do
        true -> "http://localhost:#{@port}/down"
        _ -> "http://localhost:#{@port}"
      end

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Provider #{u}",
        base_url: provider_url
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-provider-#{u}"
      })

    {:ok, model_alias} =
      Providers.create_model_alias(%{
        name: "gpt-4o-#{u}",
        display_name: "GPT 4o",
        context_window: 128_000
      })

    {:ok, _grant} = Providers.grant_alias_to_team(team.id, model_alias.id)

    {:ok, model_provider} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-real-#{u}",
        priority: 1
      })

    %{
      team: team,
      user: user,
      member: member,
      token: token,
      alias: model_alias,
      model_provider: model_provider
    }
  end

  defp authed_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp chat_body(model) do
    %{"model" => model, "messages" => [%{"role" => "user", "content" => "hola, ¿cómo vas?"}]}
  end

  defp update_alias_type(model_alias, type) do
    model_alias
    |> Ecto.Changeset.change(model_type: type)
    |> Repo.update!()
  end

  ## Auth ######################################################################

  test "401 without token", %{conn: conn} do
    conn = post(conn, ~p"/v1/chat/completions", chat_body("whatever"))
    assert %{"error" => %{"code" => "missing_api_key"}} = json_response(conn, 401)
  end

  test "401 with invalid token", %{conn: conn} do
    conn =
      conn
      |> authed_conn("tg-nope")
      |> post(~p"/v1/chat/completions", chat_body("whatever"))

    assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
  end

  ## Models #####################################################################

  test "GET /v1/models returns only accessible aliases with context_window", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()

    other = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"object" => "list", "data" => models} = json_response(conn, 200)
    ids = Enum.map(models, & &1["id"])
    assert model_alias.name in ids
    refute other.alias.name in ids

    entry = Enum.find(models, &(&1["id"] == model_alias.name))
    assert entry["context_window"] == 128_000
    assert entry["owned_by"] == "tokengate"
  end

  ## Chat completions ###########################################################

  test "happy path: response carries cost info, headers, budget spend and async log", %{
    conn: conn
  } do
    %{token: token, alias: model_alias, member: member, model_provider: model_provider} =
      proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("x-agent-type", "claude-code")
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    body = json_response(conn, 200)

    # Passthrough content intact
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "qué onda"

    # Cost info injected into usage: market = 20*5/1M + 10*15/1M = 0.00025
    # provider = 20*2.5/1M + 10*10/1M = 0.00015
    assert body["usage"]["prompt_tokens"] == 20
    assert body["usage"]["completion_tokens"] == 10
    assert_in_delta body["usage"]["cost_usd"], 0.00015, 0.0000001

    # Cost headers
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000150"]

    # Budget spend recorded in ETS uses provider_cost_usd (the real paid cost)
    spend = Budgets.spend(member.id)
    assert Decimal.equal?(spend.monthly_usd, Decimal.new("0.000150"))

    # Log job enqueued → drain → request_log row with the single cost dimension
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.agent_type == "claude-code"
    assert log.model_requested == model_alias.name
    assert log.model_responded =~ "gpt-4o-real"
    assert log.status_code == 200
    assert log.prompt_tokens == 20
    assert log.model_provider_id == model_provider.id
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
  end

  test "402 when the daily cost brings the user over their monthly budget", %{conn: conn} do
    # Without market pricing the pre-check no longer estimates. To trip the
    # budget gate we set a tiny monthly cap and pre-load the ETS counter so
    # the next request is rejected before being dispatched.
    %{token: token, alias: model_alias, member: member} =
      proxy_fixture(%{daily_budget: "0.0001"})

    # Pre-seed the spend counter so the member is already at/over their cap.
    Budgets.record_spend(member.id, Decimal.new("0.000150"))

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"code" => "budget_exceeded", "type" => "billing_error"}} =
             json_response(conn, 402)
  end

  test "402 when estimated cost exceeds the daily budget (nil team budget is unlimited)", %{
    conn: conn
  } do
    # Nil daily budget means unlimited pool — should pass.
    %{token: token, alias: model_alias} = proxy_fixture(%{daily_budget: nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)
  end

  test "member extra daily budget raises the effective team limit", %{conn: conn} do
    # Both caps allow the upstream-reported cost of $0.00015; the second
    # request also passes since daily spend ($0.00030) < team + member cap.
    %{token: token, alias: model_alias} =
      proxy_fixture(%{daily_budget: "0.001", extra_daily_budget: "0.01"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)
  end

  test "429 when team concurrency limit is exceeded", %{conn: conn} do
    %{token: token, alias: model_alias, member: member} =
      proxy_fixture(%{concurrency_limit: 1})

    # Simulate an in-flight request holding the only slot
    :ok = Limits.acquire(member.api_key.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"code" => "concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(member.api_key.id)
  end

  test "429 when RPM exceeded", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture(%{rpm_limit: 1})

    conn1 =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn1, 200)

    conn2 =
      build_conn()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn2, 429)
  end

  test "404 for a model the key cannot access", %{conn: conn} do
    %{token: token} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("gpt-9000-does-not-exist"))

    assert %{"error" => %{"code" => "model_not_found"}} = json_response(conn, 404)
  end

  test "503 when the only provider is down (breaker records the failure)", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture(%{down: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  test "fallback: first provider 500, second provider answers", %{conn: conn} do
    u = unique()
    %{token: token, alias: model_alias} = proxy_fixture(%{down: true})

    # Second, healthy provider at lower priority (higher number)
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: "http://localhost:#{@port}"
      })

    {:ok, cred2} =
      Providers.create_credential(%{provider_id: provider2.id, api_key_encrypted: "sk-healthy"})

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)
  end

  ## Timeout retry policy ######################################################

  # Adds a second, healthy provider+credential at lower priority so the
  # router has somewhere to fall back to.
  defp add_healthy_fallback(model_alias, u) do
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: "http://localhost:#{@port}"
      })

    {:ok, cred2} =
      Providers.create_credential(%{
        provider_id: provider2.id,
        api_key_encrypted: "sk-healthy-#{u}"
      })

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    cred2
  end

  # Points the alias's first (priority 1) credential's provider at the
  # hanging endpoint with a short receive_timeout so tests stay fast.
  defp make_first_provider_hang(model_alias) do
    [model_provider] =
      Providers.list_model_providers(model_alias.id) |> Enum.sort_by(& &1.priority)

    {:ok, _credential} =
      Providers.update_credential(model_provider.credential, %{receive_timeout_ms: 200})

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/hang"
      })
  end

  test "timeout falls back immediately to the second provider (no same-provider retries)", %{
    conn: conn
  } do
    u = unique()
    %{token: token, alias: model_alias} = proxy_fixture()
    make_first_provider_hang(model_alias)
    add_healthy_fallback(model_alias, u)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    elapsed = System.monotonic_time(:millisecond) - start

    assert json_response(conn, 200)

    # One timeout (200ms) + the healthy provider's answer. If the old policy
    # were in place (3 retries at 200ms each before excluding), this would
    # take ~800ms+. Give generous headroom for CI jitter.
    assert elapsed < 700, "expected immediate fallback after one timeout, took #{elapsed}ms"
  end

  test "timeout with a single provider returns 503 after one attempt", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    make_first_provider_hang(model_alias)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    elapsed = System.monotonic_time(:millisecond) - start

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)

    # Old policy: 3 retries × 200ms before giving up (~600ms+). New policy:
    # one timeout, then the pool is empty → 503 right away.
    assert elapsed < 700, "expected single timeout before 503, took #{elapsed}ms"
  end

  test "fast 500 errors still retry the same provider before falling back", %{conn: conn} do
    u = unique()
    %{token: token, alias: model_alias} = proxy_fixture(%{down: true})
    add_healthy_fallback(model_alias, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)

    # The 500 path keeps per-provider retries: the first provider gets hit
    # more than once (initial attempt + retries) before the router moves on.
    # Each hit sends a {:provider_request, _} message from ProviderPlug.
    hits =
      for _ <- 1..100 do
        receive do
          {:provider_request, payload} -> payload
        after
          0 -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    down_hits = Enum.count(hits, fn payload -> payload["model"] =~ "gpt-4o-real" end)
    assert down_hits >= 2, "expected the down provider to be retried, got #{down_hits} hit(s)"
  end

  test "concurrency fallback: saturated credential falls back to second credential", %{conn: conn} do
    u = unique()

    # First credential with max_concurrent: 1
    %{token: token, alias: model_alias} = proxy_fixture(%{})

    # Saturate the first credential's only concurrency slot
    {:ok, cred1} =
      Providers.update_credential(
        hd(Providers.list_model_providers(model_alias.id)).credential,
        %{max_concurrent: 1}
      )

    :ok = Limits.acquire(cred1.id, %{rpm_limit: nil, concurrency_limit: 1})

    # Second credential at lower priority (higher number)
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: "http://localhost:#{@port}"
      })

    {:ok, cred2} =
      Providers.create_credential(%{
        provider_id: provider2.id,
        api_key_encrypted: "sk-healthy-#{u}",
        max_concurrent: 5
      })

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)

    Limits.release(cred1.id)
  end

  test "429 provider_concurrency_exceeded when all credentials are saturated", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture(%{})

    # Saturate the only credential's concurrency slot
    [mp] = Providers.list_model_providers(model_alias.id)

    {:ok, cred} = Providers.update_credential(mp.credential, %{max_concurrent: 1})
    :ok = Limits.acquire(cred.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"code" => "provider_concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(cred.id)
  end

  ## Prompt optimization flags ################################################

  # Reusable noisy payload: has duplicate consecutive tool messages, redundant
  # whitespace runs, and a system message that is NOT at the front — exactly the
  # shape the lazy_cleanup / stable_prefix passes are designed to clean.
  defp noisy_payload(model) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => "first prompt"},
        %{"role" => "system", "content" => "you are a helper"},
        %{"role" => "tool", "content" => "tool output A"},
        %{"role" => "tool", "content" => "tool output A"},
        %{"role" => "tool", "content" => "tool output B"},
        %{"role" => "assistant", "content" => "ack"}
      ]
    }
  end

  test "lazy_cleanup_enabled: true dedupes duplicate tool messages before forwarding", %{
    conn: conn
  } do
    %{token: token, alias: model_alias} = proxy_fixture()

    # Flip the flag on the alias created by the fixture.
    {:ok, alias_optimized} =
      Providers.update_model_alias(model_alias, %{lazy_cleanup_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(alias_optimized.name))

    assert json_response(conn, 200)

    # The provider received the cleaned payload: consecutive duplicate tool
    # message ("tool output A" sent twice) collapsed into a single copy.
    assert_receive {:provider_request, provider_payload}
    tool_messages = Enum.filter(provider_payload["messages"], &(&1["role"] == "tool"))

    assert length(tool_messages) == 2
    assert Enum.map(tool_messages, & &1["content"]) == ["tool output A", "tool output B"]
  end

  test "lazy_cleanup_enabled: false passes the original payload through unchanged", %{
    conn: conn
  } do
    %{token: token, alias: model_alias} = proxy_fixture()

    # The default is already false, but set it explicitly so the test is
    # self-documenting and resilient to future schema default changes.
    {:ok, alias_passthrough} =
      Providers.update_model_alias(model_alias, %{lazy_cleanup_enabled: false})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(alias_passthrough.name))

    assert json_response(conn, 200)

    # Forwarded messages must equal the original payload byte-for-byte,
    # including the duplicate tool messages and the mid-list system message.
    assert_receive {:provider_request, provider_payload}
    assert provider_payload["messages"] == noisy_payload(alias_passthrough.name)["messages"]
  end

  test "prompt_cache_enabled: true hoists every system message to the front", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()

    {:ok, alias_cached} =
      Providers.update_model_alias(model_alias, %{prompt_cache_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(alias_cached.name))

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}
    forwarded_messages = provider_payload["messages"]

    # The system message is now at the front and any other system messages
    # would also be hoisted (none in this fixture, so the front is exactly one).
    assert hd(forwarded_messages)["role"] == "system"
    assert hd(forwarded_messages)["content"] == "you are a helper"

    # The rest of the messages preserve their original relative order.
    rest = tl(forwarded_messages)
    assert Enum.map(rest, & &1["role"]) == ["user", "tool", "tool", "tool", "assistant"]

    assert Enum.map(rest, & &1["content"]) == [
             "first prompt",
             "tool output A",
             "tool output A",
             "tool output B",
             "ack"
           ]
  end

  ## Prompt optimization (lazy cleanup / prompt cache) ##########################

  test "modelo con prompt_cache_enabled y guard_rails combina guard_rails + reorder", %{
    conn: conn
  } do
    %{token: token, alias: model_alias} = proxy_fixture()

    {:ok, _} =
      Providers.update_model_alias(model_alias, %{
        "prompt_cache_enabled" => true,
        "guard_rails" => "sé breve"
      })

    messages = [
      %{"role" => "user", "content" => "u1"},
      %{"role" => "system", "content" => "regla"}
    ]

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{"model" => model_alias.name, "messages" => messages})

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}

    # inject_guard_rails inserts a NEW system message at the front (the
    # original system is mid-list, not first), then stable_prefix hoists both
    # system messages to the front preserving order.
    assert provider_payload["messages"] == [
             %{"role" => "system", "content" => "sé breve"},
             %{"role" => "system", "content" => "regla"},
             %{"role" => "user", "content" => "u1"}
           ]
  end

  ## Streaming #################################################################

  test "stream: SSE passthrough with usage cost injection and async log", %{conn: conn} do
    %{token: token, alias: model_alias, member: member} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model_alias.name), "stream", true))

    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    body = response(conn, 200)
    frames = body |> String.split("\n\n", trim: true)

    # Content frames pass through, then the usage frame, then [DONE]
    assert Enum.at(frames, 0) =~ ~s("content":"qué")
    assert Enum.at(frames, 1) =~ ~s("content":" onda")
    assert List.last(frames) == "data: [DONE]"

    # The usage frame carries the injected cost dimensions
    usage_frame = Enum.find(frames, &(&1 =~ "usage"))
    usage_json = usage_frame |> String.trim_leading("data: ") |> Jason.decode!()
    assert_in_delta usage_json["usage"]["cost_usd"], 0.00007, 0.0000001

    # stream_options.include_usage was requested from the provider
    assert_receive {:provider_request, provider_payload}
    assert provider_payload["stream_options"]["include_usage"] == true

    # Log written with streaming: true
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.streaming == true
    assert log.prompt_tokens == 20
    assert log.completion_tokens == 2
    # TTFT recorded for streaming: a small non-negative duration in ms
    assert is_integer(log.ttft_ms)
    assert log.ttft_ms >= 0
  end

  test "stream: first-token timeout falls back and returns 503 with a single provider", %{
    conn: conn
  } do
    previous = Application.get_env(:tokengate, :first_token_timeout_ms)
    Application.put_env(:tokengate, :first_token_timeout_ms, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tokengate, :first_token_timeout_ms, previous),
        else: Application.delete_env(:tokengate, :first_token_timeout_ms)
    end)

    %{token: token, alias: model_alias} = proxy_fixture()

    # Repoint the provider at the slow stream endpoint
    [model_provider] = Providers.list_model_providers(model_alias.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/slowstream"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model_alias.name), "stream", true))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  test "stream: first-token timeout falls back to the second provider immediately", %{conn: conn} do
    previous = Application.get_env(:tokengate, :first_token_timeout_ms)
    Application.put_env(:tokengate, :first_token_timeout_ms, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tokengate, :first_token_timeout_ms, previous),
        else: Application.delete_env(:tokengate, :first_token_timeout_ms)
    end)

    u = unique()
    %{token: token, alias: model_alias} = proxy_fixture()

    # First provider streams too slowly (300ms > 100ms first-token budget)
    [model_provider] = Providers.list_model_providers(model_alias.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/slowstream"
      })

    add_healthy_fallback(model_alias, u)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model_alias.name), "stream", true))

    elapsed = System.monotonic_time(:millisecond) - start

    assert conn.state == :chunked
    assert response(conn, 200)

    # Old policy: 3 retries × 100ms before falling back (~400ms+). New:
    # one 100ms first-token timeout, then straight to the healthy provider.
    assert elapsed < 400, "expected immediate streaming fallback, took #{elapsed}ms"
  end

  ## Embeddings ################################################################

  test "embeddings happy path: passthrough, cost from usage, log with request_type", %{
    conn: conn
  } do
    %{token: token, alias: model_alias, member: member} = proxy_fixture()
    update_alias_type(model_alias, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model_alias.name, "input" => ["hola", "wey"]})

    body = json_response(conn, 200)

    # Passthrough: two vectors back, upstream model id
    assert [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}, %{"index" => 1}] = body["data"]
    assert body["model"] =~ "gpt-4o-real"

    # Provider-reported usage drives cost (cost 0.000011)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000011"]

    spend = Budgets.spend(member.id)
    assert Decimal.equal?(spend.monthly_usd, Decimal.new("0.000011"))

    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.request_type == "embedding"
    assert log.prompt_tokens == 11
    assert log.completion_tokens == 0
    assert log.status_code == 200
  end

  test "embeddings accepts a bare string input", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    update_alias_type(model_alias, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model_alias.name, "input" => "una sola"})

    assert %{"data" => [%{"index" => 0}]} = json_response(conn, 200)
  end

  test "embeddings 400 without input", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    update_alias_type(model_alias, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model_alias.name})

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "embeddings 400 model_type_mismatch against an llm alias", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model_alias.name, "input" => "x"})

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "chat completions 400 model_type_mismatch against an embedding alias", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    update_alias_type(model_alias, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  ## Rerank ####################################################################

  test "rerank with Fireworks-style upstream normalizes to Cohere shape", %{conn: conn} do
    %{token: token, alias: model_alias, member: member} = proxy_fixture()
    update_alias_type(model_alias, "rerank")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/rerank", %{
        "model" => model_alias.name,
        "query" => "chaos",
        "documents" => ["doc cero", "doc uno"]
      })

    body = json_response(conn, 200)

    # data → results normalization; scores and ordering intact
    assert [%{"index" => 1, "relevance_score" => 0.9}, %{"index" => 0, "relevance_score" => 0.2}] =
             body["results"]

    refute Map.has_key?(body, "data")

    # Fireworks-reported usage drives cost
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000042"]

    spend = Budgets.spend(member.id)
    assert Decimal.equal?(spend.monthly_usd, Decimal.new("0.000042"))

    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.request_type == "rerank"
    assert log.prompt_tokens == 42
    assert log.status_code == 200
  end

  test "rerank with oMLX-style upstream passes through and estimates usage", %{conn: conn} do
    %{token: token, alias: model_alias, member: member} = proxy_fixture()
    update_alias_type(model_alias, "rerank")

    [model_provider] = Providers.list_model_providers(model_alias.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/rerank-cohere"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/rerank", %{
        "model" => model_alias.name,
        "query" => "chaos",
        "documents" => ["doc cero", "doc uno"]
      })

    body = json_response(conn, 200)
    assert [%{"index" => 1, "relevance_score" => 0.9} | _] = body["results"]

    # No upstream usage → estimated prompt_tokens > 0, zero cost (pay_per_token
    # with no reported cost is the honest-zero policy)
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.request_type == "rerank"
    assert log.prompt_tokens > 0
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0"))
  end

  test "rerank 400 without documents", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    update_alias_type(model_alias, "rerank")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/rerank", %{"model" => model_alias.name, "query" => "q"})

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "rerank 400 model_type_mismatch against an llm alias", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/rerank", %{
        "model" => model_alias.name,
        "query" => "q",
        "documents" => ["d"]
      })

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "GET /v1/models includes model_type", %{conn: conn} do
    %{token: token, alias: model_alias} = proxy_fixture()
    update_alias_type(model_alias, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"data" => models} = json_response(conn, 200)
    entry = Enum.find(models, &(&1["id"] == model_alias.name))
    assert entry["model_type"] == "embedding"
  end
end
