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

        "slowstream" in conn.path_info ->
          Process.sleep(300)
          stream(conn)

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
              "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30}
            })
          end
      end
    end

    defp stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, ~s(data: {"choices":[{"delta":{"content":"qué"}}]}\n\n))
      {:ok, conn} = chunk(conn, ~s(data: {"choices":[{"delta":{"content":" onda"}}]}\n\n))

      {:ok, conn} =
        chunk(
          conn,
          ~s(data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22}}\n\n)
        )

      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
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
        default_daily_budget_usd: Map.get(opts, :daily_budget, "100.00"),
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
        extra_daily_budget_usd: Map.get(opts, :extra_daily_budget),
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
        market_input_price_per_1m: "5.00",
        market_output_price_per_1m: "15.00",
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

    {:ok, _pricing} =
      Providers.create_model_pricing(%{
        model_provider_id: model_provider.id,
        input_price_per_1m: "2.50",
        output_price_per_1m: "10.00",
        effective_from: DateTime.truncate(DateTime.utc_now(), :second)
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
    assert_in_delta body["usage"]["estimated_cost_usd"], 0.00025, 0.0000001
    assert_in_delta body["usage"]["cost_usd"], 0.00015, 0.0000001

    # Cost headers
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000150"]
    assert get_resp_header(conn, "x-tokengate-savings") == ["0.000100"]

    # Budget spend recorded in ETS uses provider_cost_usd (the real paid cost)
    spend = Budgets.spend(member.id)
    assert Decimal.equal?(spend.daily_usd, Decimal.new("0.000150"))

    # Log job enqueued → drain → request_log row with all 4 dimensions
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.team_member_id == ^member.id)
    assert log.agent_type == "claude-code"
    assert log.model_requested == model_alias.name
    assert log.model_responded =~ "gpt-4o-real"
    assert log.status_code == 200
    assert log.prompt_tokens == 20
    assert log.model_provider_id == model_provider.id
    assert Decimal.equal?(log.cost_usd, Decimal.new("0.000150"))
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
    assert Decimal.equal?(log.estimated_cost_usd, Decimal.new("0.000250"))
    assert Decimal.equal?(log.savings_usd, Decimal.new("0.000100"))
  end

  test "402 when estimated cost exceeds the daily budget", %{conn: conn} do
    # Estimated completion = 512 tokens → market cost ≈ 20*5/1M + 512*15/1M ≈ 0.00778
    %{token: token, alias: model_alias} = proxy_fixture(%{daily_budget: "0.001"})

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
    # Team default 0.001 would reject (~0.00778 estimated); the member's
    # extra 0.01 raises the effective limit to 0.011, so the request passes.
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

    {:ok, ap2} =
      Providers.create_model_provider(%{
        model_alias_id: model_alias.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    {:ok, _} =
      Providers.create_model_pricing(%{
        model_provider_id: ap2.id,
        input_price_per_1m: "2.50",
        output_price_per_1m: "10.00",
        effective_from: DateTime.truncate(DateTime.utc_now(), :second)
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model_alias.name))

    assert json_response(conn, 200)
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
    assert_in_delta usage_json["usage"]["estimated_cost_usd"], 0.00013, 0.0000001
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
end
