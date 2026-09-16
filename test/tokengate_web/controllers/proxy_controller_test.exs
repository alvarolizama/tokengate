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
  alias Tokengate.Routing.CircuitBreakerManager

  @port 41236
  @boundary "tg-upload-boundary"

  # A real multipart/form-data body for the stt surface: a form field plus a
  # file part whose bytes are binary (invalid UTF-8 on purpose — the
  # byte-for-byte assertion must not depend on the body being text).
  defp multipart_body(model, filename \\ "audio.wav") do
    IO.iodata_to_binary([
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="model"\r\n\r\n),
      "#{model}\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="#{filename}"\r\n),
      "content-type: audio/wav\r\n\r\n",
      <<0x52, 0x49, 0xFF, 0x00, 0x46, 0x4D>>,
      "\r\n",
      "--",
      @boundary,
      "--\r\n"
    ])
  end

  defmodule ProviderPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      # JSON only: a multipart body has no JSON to decode, so it is captured
      # raw instead. `{:provider_request, payload}` keeps its historical shape
      # for the JSON tests; the raw body rides its own message.
      payload = decode_json(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:provider_raw_body, body, conn.req_headers})
        if payload != nil, do: send(pid, {:provider_request, payload})
        send(pid, {:provider_request_headers, conn.req_headers})
        send(pid, {:provider_request_path, conn.request_path})
      end

      route(conn, body, payload || %{})
    end

    defp decode_json(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> nil
      end
    end

    defp route(conn, body, payload) do
      cond do
        # Simulates a strictly-validating upstream (Fireworks): any of the
        # configured fields present in the body is a hard 400.
        rejected = rejected_fields(payload) ->
          json(conn, 400, %{
            "error" => %{
              "message" => "Extra inputs are not permitted, field: '#{rejected}'",
              "code" => 400
            }
          })

        "down" in conn.path_info ->
          json(conn, 500, %{"error" => %{"message" => "provider exploded"}})

        # Simulates a provider that rejects the request body for its own
        # reasons (400) while the next candidate would accept it.
        "badrequest" in conn.path_info ->
          json(conn, 400, %{
            "error" => %{"message" => "Invalid parameter: unsupported field", "code" => 400}
          })

        # Simulates an upstream answering a 4xx other than 400 (the caller's
        # payload at fault, not a provider-specific rejection).
        "notfound" in conn.path_info ->
          json(conn, 404, %{"error" => %{"message" => "model not found upstream"}})

        # A tts surface that answers with real audio bytes instead of JSON —
        # the binary passthrough the client must receive untouched.
        "costly-binary-speech" in conn.path_info ->
          conn
          |> put_resp_content_type("audio/mpeg")
          |> put_resp_header("x-litellm-response-cost", "0.000420")
          |> send_resp(200, <<0xFF, 0xFB, 0x90, 0x01>>)

        "binary-speech" in conn.path_info ->
          conn
          |> put_resp_content_type("audio/mpeg")
          |> send_resp(200, <<0xFF, 0xFB, 0x90, 0x00>>)

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

        # The six non-chat services, each answered with a shape of its own.
        # `images` and `music` share the `/generations` segment, so every one
        # of them is matched by its own marker — an operator override that
        # keeps the segment (as in the override test) still lands here.
        "rerank" in conn.path_info ->
          json(conn, 200, %{
            "results" => [%{"index" => 0, "relevance_score" => 0.91}],
            "usage" => %{"prompt_tokens" => 12, "total_tokens" => 12}
          })

        "transcriptions" in conn.path_info ->
          json(conn, 200, %{"text" => "hola mundo"})

        "speech" in conn.path_info ->
          json(conn, 200, %{"audio" => "SUQzBAAAAAA"})

        "images" in conn.path_info ->
          json(conn, 200, %{
            "created" => 1,
            "data" => [%{"b64_json" => "aW1n"}],
            "usage" => %{"input_tokens" => 100, "output_tokens" => 200, "total_tokens" => 300}
          })

        "videos" in conn.path_info ->
          json(conn, 200, %{"id" => "video-job-1", "status" => "queued"})

        "music" in conn.path_info ->
          json(conn, 200, %{"id" => "music-1", "status" => "succeeded"})

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

    # Strict-upstream simulation (Fireworks): 400s on any field listed in
    # :persistent_term under {ProviderPlug, :reject_body_fields}.
    defp rejected_fields(payload) do
      reject = :persistent_term.get({__MODULE__, :reject_body_fields}, [])

      Enum.find(reject, &Map.has_key?(payload, &1))
    end
  end

  setup do
    :persistent_term.put({ProviderPlug, :test_pid}, self())
    :persistent_term.put({ProviderPlug, :reject_body_fields}, [])
    start_supervised!({Bandit, plug: ProviderPlug, scheme: :http, ip: :loopback, port: @port})
    :ok
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  defp proxy_fixture(opts \\ %{}) do
    u = unique()

    # El gasto del grupo ahora es su límite mensual. Sin `:credit_units` y sin
    # `:unlimited` el grupo NO deja gastar (los miembros quedarían sin camino
    # salvo top-up) — que es exactamente la conducta nueva.
    group_attrs =
      %{
        name: "Group #{u}",
        default_rpm_limit: Map.get(opts, :rpm_limit, 600),
        default_concurrency_limit: Map.get(opts, :concurrency_limit, 10)
      }
      |> then(fn attrs ->
        cond do
          # Default del fixture: ILIMITADO (espejo del tier-3 de antes), para
          # que los tests que no hablan de crédito no tropiecen con el gate.
          Map.get(opts, :credit_units) -> Map.put(attrs, :monthly_spend_limit_usd, to_string(opts.credit_units))
          Map.get(opts, :blocked) -> attrs
          true -> Map.put(attrs, :unlimited_spend, true)
        end
      end)

    {:ok, group} = Accounts.create_group(group_attrs)

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{u}@example.com",
        name: "User #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{
        user_id: user.id,
        group_id: group.id,
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
        base_url: provider_url,
        billing_type: Map.get(opts, :billing_type, "pay_per_token"),
        path_overrides: Map.get(opts, :path_overrides, %{})
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-provider-#{u}"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: "gpt-4o-#{u}",
        context_window: 128_000
      })

    {:ok, _grant} = Providers.grant_model_to_group(group.id, model.id)

    {:ok, model_provider} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-real-#{u}",
        priority: 1
      })

    %{
      group: group,
      user: user,
      member: member,
      token: token,
      provider: provider,
      model: model,
      model_provider: model_provider,
      # El límite mensual del grupo (nil = sin límite propio): es lo que el
      # proxy debita y lo que los tests comparan contra el gasto.
      credit_limit_usd: group.monthly_spend_limit_usd
    }
  end

  defp authed_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp chat_body(model) do
    %{"model" => model, "messages" => [%{"role" => "user", "content" => "hola, ¿cómo vas?"}]}
  end

  defp update_alias_type(model, type) do
    model
    |> Ecto.Changeset.change(model_type: type)
    |> Repo.update!()
  end

  # Puts spend on a subject's books (zero-hold settle) so budget-gate tests can
  # start from an already-spent state.
  defp record(subject_id, cost_usd) do
    Budgets.settle(
      subject_id,
      %{monthly_micro: 0, global_micro: 0, exempt_global?: false},
      cost_usd
    )
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

  test "GET /v1/models returns only accessible models with context_window", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    other = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"object" => "list", "data" => models} = json_response(conn, 200)
    ids = Enum.map(models, & &1["id"])
    assert model.name in ids
    refute other.model.name in ids

    entry = Enum.find(models, &(&1["id"] == model.name))
    assert entry["context_window"] == 128_000
    assert entry["owned_by"] == "tokengate"
  end

  ## Chat completions ###########################################################

  test "happy path: response carries cost info, headers, credit spend and async log", %{
    conn: conn
  } do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } = proxy_fixture(%{credit_units: 100})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("x-agent-type", "claude-code")
      |> post(~p"/v1/chat/completions", chat_body(model.name))

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

    # The request debits the member's credit grant by the real paid cost
    # (0.000150 USD = 150 micro-USD = 150 units of crédito at 1:1).
    assert %{consumed_micro: 150} = Budgets.limit_spend({:user, member.user_id})

    # Log job enqueued → drain → request_log row with the single cost dimension
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.agent_type == "claude-code"
    assert log.model_requested == model.name
    assert log.model_responded =~ "gpt-4o-real"
    assert log.status_code == 200
    assert log.prompt_tokens == 20
    assert log.model_provider_id == model_provider.id
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
  end

  test "402 when the user's credit is exhausted", %{conn: conn} do
    # A zero-credit group subscription: the member's only grant has no room, so
    # the next request is rejected before being dispatched.
    %{token: token, model: model} = proxy_fixture(%{credit_units: 0})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "budget_exceeded", "type" => "billing_error"}} =
             json_response(conn, 402)
  end

  test "402 when the global daily kill-switch is reached", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture()

    # Arm the org-wide kill-switch and put spend on the books for today so the
    # global counter is at the cap.
    {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => "0.01"})
    record(member.id, Decimal.new("0.01"))

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "budget_exceeded", "type" => "billing_error"}} =
             json_response(conn, 402)
  end

  @tag :capture_log
  test "rejected budget requests do not leak group concurrency slots", %{conn: conn} do
    # Regression: budget gates used to run AFTER acquire_group_limits, and the
    # concurrency slot was only released inside the try/after that never ran
    # when the `with` short-circuited. N rejected requests leaked N slots and
    # the member ended up permanently 429-blocked (no sweeper on the
    # in-flight table).
    %{token: token, model: model, member: member, group: group} =
      proxy_fixture(%{credit_units: 0, concurrency_limit: 3})

    # Member's credit is exhausted → every request 402s.
    for _ <- 1..3 do
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))
    end

    # The leaked slots would pin the in-flight count at the limit...
    assert Limits.current_concurrency(member.api_key.id) == 0

    # ...and block forever: refill the credit (and drop the cached auth so the
    # new grant amount is picked up) — the 4th request must NOT be blocked.
    {:ok, _} = Accounts.update_group(group, %{"monthly_spend_limit_usd" => "100.00"})
    Tokengate.Accounts.ApiKeyCache.invalidate_group(group.id)

    conn
    |> authed_conn(token)
    |> post(~p"/v1/chat/completions", chat_body(model.name))
    |> json_response(200)
  end

  test "a subscription provider is not exempt from an exhausted credit", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{credit_units: 0, billing_type: "subscription"})

    # Exhausted credit + no billing-surface exemption: the gate rejects it,
    # exactly as it would for a pay_per_token provider.
    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 402)
  end

  test "402 when estimated cost exceeds the daily budget (nil group budget is unlimited)", %{
    conn: conn
  } do
    # Nil daily budget means unlimited pool — should pass.
    %{token: token, model: model} = proxy_fixture(%{daily_budget: nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "member extra daily budget raises the effective group limit", %{conn: conn} do
    # Both caps allow the upstream-reported cost of $0.00015; the second
    # request also passes since daily spend ($0.00030) < group + member cap.
    %{token: token, model: model} =
      proxy_fixture(%{daily_budget: "0.001", extra_daily_budget: "0.01"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "429 when group concurrency limit is exceeded", %{conn: conn} do
    %{token: token, model: model, member: member} =
      proxy_fixture(%{concurrency_limit: 1})

    # Simulate an in-flight request holding the only slot
    :ok = Limits.acquire(member.api_key.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(member.api_key.id)
  end

  test "429 when RPM exceeded", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{rpm_limit: 1})

    conn1 =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn1, 200)

    conn2 =
      build_conn()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn2, 429)
  end

  test "429 rate-limit responses carry a Retry-After header", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{rpm_limit: 1})

    conn1 =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn1, 200)

    conn2 =
      build_conn()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn2, 429)
    [retry_after] = get_resp_header(conn2, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  test "cascade exhausted on rate limits reports provider_rate_limited (not concurrency)", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the provider's RPM so every route attempt is rejected with
    # provider_rate_limited — the cascade then exhausts on rate limits.
    [mp] = Providers.list_model_providers(model.id)
    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_rpm: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: 1, concurrency_limit: nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_rate_limited"}} = json_response(conn, 429)

    Limits.release(cred.id)
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
    %{token: token, model: model} = proxy_fixture(%{down: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  test "fallback: first provider 500, second provider answers", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})

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
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "fallback: the failed attempt log carries the upstream error message", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})

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
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # The down provider 500s fast, so it gets @max_retries_per_provider
    # attempts before being excluded (each one logs a fallback entry), then
    # the healthy provider answers and logs the final success: 3 + 1 jobs.
    assert %{success: 4} = Oban.drain_queue(queue: :logs)

    fallback_logs =
      Repo.all(
        from l in RequestLog,
          where: l.model_id == ^model.id and l.error_reason == "provider_internal_error"
      )

    assert fallback_logs != []

    Enum.each(fallback_logs, fn log ->
      assert log.status_code == 200
      assert log.provider_status_code == 500
      assert log.error_message == "provider exploded"
    end)
  end

  ## Timeout retry policy ######################################################

  # Adds a second, healthy provider+credential at lower priority so the
  # router has somewhere to fall back to.
  defp add_healthy_fallback(model, u) do
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
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    cred2
  end

  # Points the model's first (priority 1) credential's provider at the
  # hanging endpoint with a short receive_timeout so tests stay fast.
  defp make_first_provider_hang(model) do
    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/hang",
        receive_timeout_ms: 200
      })
  end

  # Points the model's first (priority 1) provider at an endpoint that always
  # answers 400 — a body that provider refuses for its own reasons, while the
  # fallback candidate serves it. Returns the credential id.
  defp make_first_provider_reject(model) do
    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/badrequest"
      })

    model_provider.credential_id
  end

  # Drains every {:provider_request, _} message ProviderPlug sent — one per
  # upstream attempt (retries and fallbacks included).
  defp collect_provider_hits do
    for _ <- 1..100 do
      receive do
        {:provider_request, payload} -> payload
      after
        0 -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  test "timeout falls back immediately to the second provider (no same-provider retries)", %{
    conn: conn
  } do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    make_first_provider_hang(model)
    add_healthy_fallback(model, u)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    elapsed = System.monotonic_time(:millisecond) - start

    assert json_response(conn, 200)

    # One timeout (200ms) + the healthy provider's answer. If the old policy
    # were in place (3 retries at 200ms each before excluding), this would
    # take ~800ms+. Give generous headroom for CI jitter.
    assert elapsed < 700, "expected immediate fallback after one timeout, took #{elapsed}ms"
  end

  test "timeout with a single provider returns 503 after one attempt", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    make_first_provider_hang(model)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    elapsed = System.monotonic_time(:millisecond) - start

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)

    # Old policy: 3 retries × 200ms before giving up (~600ms+). New policy:
    # one timeout, then the pool is empty → 503 right away.
    assert elapsed < 700, "expected single timeout before 503, took #{elapsed}ms"
  end

  test "fast 500 errors still retry the same provider before falling back", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

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

  ## Idempotency-Key #########################################################

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp idempotency_key_from(headers) do
    Enum.find_value(headers, fn
      {"idempotency-key", value} -> value
      _ -> nil
    end)
  end

  # Drains every {:provider_request_headers, _} message from the mailbox.
  defp collect_upstream_headers do
    for _ <- 1..100 do
      receive do
        {:provider_request_headers, headers} -> List.flatten(headers)
      after
        0 -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  test "every upstream request carries x-session-affinity with the API key hash", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()

    affinity =
      Enum.find_value(headers, fn
        {"x-session-affinity", value} -> value
        _ -> nil
      end)

    # Stable per API key (sha256 of the presented token) — this is the hint
    # providers use to group a session's requests onto their cached prefix.
    assert affinity == Tokengate.Accounts.hash_api_key(token)
  end

  test "every upstream attempt carries the same Idempotency-Key", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()
    key = idempotency_key_from(headers)
    assert is_binary(key), "expected an Idempotency-Key header upstream"
    assert key =~ @uuid_regex
  end

  test "retries and provider fallback reuse the same Idempotency-Key", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # Down provider gets the initial attempt + retries, then the healthy
    # provider answers — all of them must carry one and the same key.
    keys =
      collect_upstream_headers()
      |> Enum.map(&idempotency_key_from/1)

    assert length(keys) >= 2, "expected multiple upstream attempts, got #{length(keys)}"
    assert Enum.all?(keys, &is_binary/1), "every attempt must carry the key"
    assert Enum.uniq(keys) |> length() == 1, "expected one stable key across attempts"
  end

  ## Per-provider request overrides ###########################################

  # Reproduces the Fireworks 400 regression: the gateway injects
  # `session_id` (OpenRouter's routing hint) into every chat body and
  # Fireworks strictly rejects unknown fields. With the model_provider
  # override omit_body_fields=["session_id"] the same request passes.
  #
  # The body needs a system + user opener so SessionId.derive/2 produces a
  # fingerprint session_key — that's what triggers the gateway injection.
  test "omit_body_fields strips gateway-injected fields for the strict upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} = Providers.update_model_provider(mp, %{omit_body_fields: ["session_id"]})
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["session_id"])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} -> refute Map.has_key?(payload, "session_id")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  test "a 400 that every candidate rejects is surfaced to the client", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})
    # A field the gateway does NOT know about and therefore never strips: the
    # operator-configured strict upstream rejects it. The gateway now walks the
    # candidate pool on a 400 (the rejection can be provider-specific), but with
    # a single candidate there is nowhere to go — the upstream 4xx must reach
    # the client untouched, never a 503.
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["totally_unknown_field"])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "totally_unknown_field" => "x",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert %{"error" => %{"code" => "upstream_client_error"}} = json_response(conn, 400)
  end

  # A 400 means "this body is wrong for ME", not "this credential is sick": the
  # request must reach the next candidate, and the provider that rejected it
  # must pay no price at all — credential stays active, breaker counts nothing.
  test "a 400 falls back to the next provider and leaves the rejecting one untouched" do
    u = unique()
    %{model: model, member: member} = proxy_fixture()
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    # More rounds than the breaker threshold (5): if a 400 counted as a failure
    # the breaker would be open by now and the credential excluded from the
    # pool. A fresh API key per round keeps the router's sticky routing (keyed
    # by api_key_hash + model) from pinning later rounds to the provider that
    # already answered, so every round starts at the rejecting one.
    for i <- 1..6 do
      {:ok, _api_key, token} = Accounts.replace_api_key(member)

      conn =
        build_conn()
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [%{"role" => "user", "content" => "hola #{i} (#{u})"}]
        })

      assert %{"choices" => [%{"message" => %{"content" => "qué onda"}}]} =
               json_response(conn, 200)
    end

    hits = collect_provider_hits()
    rejects = Enum.count(hits, &(&1["model"] =~ "gpt-4o-real"))
    served = Enum.count(hits, &(&1["model"] =~ "gpt-4o-healthy"))

    # One attempt per provider per round: a 400 is never replayed to the
    # provider that just rejected it.
    assert rejects == 6, "expected 6 rejections from the primary provider, got #{rejects}"
    assert served == 6, "expected 6 answers from the fallback, got #{served}"

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # Catalog-driven: a model_provider backed by a provider whose catalog key
  # is "fireworks-ai" must NEVER receive session_id (Fireworks 400s on unknown
  # body fields) without any operator configuring omit_body_fields. The hint
  # narrowing is provider knowledge (Catalog.session_hint_fields/1), not
  # per-row data. The fixture's custom provider keeps its local test URL —
  # only the catalog key is stamped onto it (builtin rows are identity-locked
  # and point at the real Fireworks endpoint).
  test "a fireworks-keyed provider never receives session_id (catalog-driven)", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    make_provider_fireworks(model)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        refute Map.has_key?(payload, "session_id"),
               "fireworks must not receive the OpenRouter-style session_id"

        assert Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  # Points the model's only model_provider at a provider whose catalog key is
  # "fireworks-ai", keeping the fixture's local test URL. Builtin rows are
  # identity-locked (they point at the real Fireworks endpoint), so the
  # builtin is dropped and the local provider row gets stamped with the key.
  defp make_provider_fireworks(model) do
    [mp] = Providers.list_model_providers(model.id)
    credential = Repo.get!(Tokengate.Providers.Credential, mp.credential_id)
    provider = Repo.get!(Tokengate.Providers.Provider, credential.provider_id)

    case Repo.get_by(Tokengate.Providers.Provider, key: "fireworks-ai") do
      nil -> :ok
      builtin -> {:ok, _} = Repo.delete(builtin)
    end

    {:ok, _} = Providers.update_provider(provider, %{key: "fireworks-ai"})
    Tokengate.Routing.Cache.invalidate_all()
  end

  # Regression: the exact Fireworks case. The CLIENT puts `session_id` in the
  # body (OpenRouter's convention); Fireworks validates strictly and 400s on
  # unknown fields. The catalog declares session_id as omit_body_fields for
  # fireworks, so the gateway must STRIP it even though the client sent it —
  # `attach_session_hint` alone only narrows what the gateway adds.
  test "a client-supplied session_id is stripped before reaching fireworks", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    make_provider_fireworks(model)
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["session_id"])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "session_id" => "client-conv-abc",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    # A 200 proves the strict upstream did not see session_id (it 400s on it).
    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        refute Map.has_key?(payload, "session_id")
        assert Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  test "extra_body merges operator fields into the upstream payload", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} =
      Providers.update_model_provider(mp, %{extra_body: %{"service_tier" => "priority"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        assert payload["service_tier"] == "priority"
        # Gateway-owned keys are protected from override merges.
        refute Map.has_key?(payload, "extra_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  test "omit_headers removes forwarded hints for the upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} = Providers.update_model_provider(mp, %{omit_headers: ["x-session-id"]})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("user-agent", "test-agent/1.0")
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    headers = List.flatten(collect_upstream_headers())

    refute Enum.any?(headers, fn {k, _v} -> k == "x-session-id" end)
    # Non-omitted forwarded headers still travel.
    assert Enum.any?(headers, fn {k, v} -> k == "user-agent" and v == "test-agent/1.0" end)
  end

  test "embeddings requests also carry an Idempotency-Key", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{
        "model" => model.name,
        "input" => ["hola mundo"]
      })

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()
    key = idempotency_key_from(headers)
    assert is_binary(key) and key =~ @uuid_regex
  end

  test "concurrency fallback: saturated credential falls back to second credential", %{conn: conn} do
    u = unique()

    # First credential with max_concurrent: 1
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the first credential's only concurrency slot
    mp1 = hd(Providers.list_model_providers(model.id))
    {:ok, _provider1} = Providers.update_provider(mp1.credential.provider, %{max_concurrent: 1})
    cred1 = mp1.credential

    :ok = Limits.acquire(cred1.id, %{rpm_limit: nil, concurrency_limit: 1})

    # Second credential at lower priority (higher number), on a provider that
    # still has headroom.
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: "http://localhost:#{@port}",
        max_concurrent: 5
      })

    {:ok, cred2} =
      Providers.create_credential(%{
        provider_id: provider2.id,
        api_key_encrypted: "sk-healthy-#{u}"
      })

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    Limits.release(cred1.id)
  end

  test "429 provider_concurrency_exceeded when all credentials are saturated", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the only credential's concurrency slot
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_concurrent: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(cred.id)
  end

  test "gate error logs carry model_id so per-model stats see them", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the only credential's concurrency slot → gate error
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_concurrent: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_concurrency_exceeded"}} = json_response(conn, 429)

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log =
      Repo.one(
        from l in RequestLog,
          where: l.error_reason == "provider_concurrency_exceeded",
          order_by: [desc: l.inserted_at],
          limit: 1
      )

    assert log.model_id == model.id
    assert log.model_requested == model.name

    Limits.release(cred.id)
  end

  ## Prompt pre-flight (mandatory for LLM models) #############################

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
    %{token: token, model: model} = proxy_fixture()

    # Flip the flag on the model created by the fixture.
    {:ok, model_optimized} =
      Providers.update_model(model, %{lazy_cleanup_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_optimized.name))

    assert json_response(conn, 200)

    # The provider received the cleaned payload: consecutive duplicate tool
    # message ("tool output A" sent twice) collapsed into a single copy.
    assert_receive {:provider_request, provider_payload}
    tool_messages = Enum.filter(provider_payload["messages"], &(&1["role"] == "tool"))

    assert length(tool_messages) == 2
    assert Enum.map(tool_messages, & &1["content"]) == ["tool output A", "tool output B"]
  end

  test "pre-flight transforms apply even with both legacy flags off (mandatory)", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    # The legacy flags are explicitly OFF: they no longer gate anything, the
    # gateway applies both passes to every LLM request.
    {:ok, model_default} =
      Providers.update_model(model, %{
        lazy_cleanup_enabled: false,
        prompt_cache_enabled: false
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_default.name))

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}

    assert Enum.map(provider_payload["messages"], & &1["role"]) == [
             "system",
             "user",
             "tool",
             "tool",
             "assistant"
           ]

    assert Enum.map(provider_payload["messages"], & &1["content"]) == [
             "you are a helper",
             "first prompt",
             "tool output A",
             "tool output B",
             "ack"
           ]
  end

  test "prompt_cache_enabled: true hoists every system message to the front", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    {:ok, model_cached} =
      Providers.update_model(model, %{prompt_cache_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_cached.name))

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}
    forwarded_messages = provider_payload["messages"]

    # The system message is now at the front and any other system messages
    # would also be hoisted (none in this fixture, so the front is exactly one).
    assert hd(forwarded_messages)["role"] == "system"
    assert hd(forwarded_messages)["content"] == "you are a helper"

    # The rest of the messages preserve their original relative order.
    # Both passes are mandatory now, so lazy_cleanup also ran and the
    # duplicated consecutive tool message arrives already collapsed.
    rest = tl(forwarded_messages)
    assert Enum.map(rest, & &1["role"]) == ["user", "tool", "tool", "assistant"]

    assert Enum.map(rest, & &1["content"]) == [
             "first prompt",
             "tool output A",
             "tool output B",
             "ack"
           ]
  end

  ## Prompt optimization (lazy cleanup / prompt cache) ##########################

  test "modelo con prompt_cache_enabled y guard_rails combina guard_rails + reorder", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    {:ok, _} =
      Providers.update_model(model, %{
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
      |> post(~p"/v1/chat/completions", %{"model" => model.name, "messages" => messages})

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
    %{token: token, model: model, member: member} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

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

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
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

    %{token: token, model: model} = proxy_fixture()

    # Repoint the provider at the slow stream endpoint
    [model_provider] = Providers.list_model_providers(model.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/slowstream"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  # A non-400 4xx on the streaming path is the caller's payload at fault, so it
  # is neither retried nor fallen back — and, like every 4xx, it must cost the
  # credential nothing. It used to be recorded through `breaker_reason/1`, whose
  # catch-all mapped it to `:server_error`, so a 404 burned the breaker of a
  # healthy credential on the streaming path only.
  test "stream: an upstream 404 is surfaced and does not count against the breaker", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    credential_id = model_provider.credential_id

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/notfound"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert %{"error" => %{"code" => "upstream_client_error"}} = json_response(conn, 404)

    # Terminal: a single attempt, no fallback.
    assert length(collect_provider_hits()) == 1

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # Regression: a 400 on the STREAMING path used to be treated like a
  # retryable server error — the gateway fell back and logged it as
  # `provider_error_400` with no message, masking the cause. A 400 IS now
  # retried across candidates (the rejection is often provider-specific), but
  # when every candidate refuses the same body the client must see the upstream
  # 4xx — never a 503 "all providers down" — and no candidate pays a price.
  test "stream: a 400 rejected by every candidate is surfaced without punishing them", %{
    conn: conn
  } do
    u = unique()
    %{token: token, model: model, model_provider: model_provider} = proxy_fixture()
    add_healthy_fallback(model, u)
    credential_id = model_provider.credential_id

    # Every upstream rejects a field the gateway does not know about, so no
    # candidate can serve this body.
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["totally_unknown_field"])

    conn =
      conn
      |> authed_conn(token)
      |> post(
        ~p"/v1/chat/completions",
        Map.put(chat_body(model.name), "stream", true)
        |> Map.put("totally_unknown_field", "x")
      )

    assert %{"error" => %{"code" => "upstream_client_error"}} = json_response(conn, 400)

    # Both candidates were tried — one attempt each: a 400 is never replayed to
    # the provider that just rejected it.
    assert length(collect_provider_hits()) == 2

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  test "stream: a 400 falls back to the next provider", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    body = response(conn, 200)
    assert body =~ ~s("content":"qué")
    assert body =~ "data: [DONE]"

    # One rejected attempt + one served attempt.
    assert length(collect_provider_hits()) == 2

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.details(credential_id).failures == 0
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
    %{token: token, model: model} = proxy_fixture()

    # First provider streams too slowly (300ms > 100ms first-token budget)
    [model_provider] = Providers.list_model_providers(model.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{@port}/slowstream"
      })

    add_healthy_fallback(model, u)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

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
    %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 100})

    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => ["hola", "wey"]})

    body = json_response(conn, 200)

    # Passthrough: two vectors back, upstream model id
    assert [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}, %{"index" => 1}] = body["data"]
    assert body["model"] =~ "gpt-4o-real"

    # Provider-reported usage drives cost (cost 0.000011)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000011"]

    assert %{consumed_micro: 11} = Budgets.limit_spend({:user, member.user_id})

    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "embedding"
    assert log.prompt_tokens == 11
    assert log.completion_tokens == 0
    assert log.status_code == 200
  end

  test "embeddings: a 400 falls back to the next provider without punishing it", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => ["hola"]})

    body = json_response(conn, 200)
    assert [%{"embedding" => [0.1, 0.2, 0.3]}] = body["data"]

    # One rejected attempt (primary) + one served attempt (the fallback).
    hits = collect_provider_hits()
    assert Enum.count(hits, &(&1["model"] =~ "gpt-4o-real")) == 1
    assert Enum.count(hits, &(&1["model"] =~ "gpt-4o-healthy")) == 1

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  test "embeddings accepts a bare string input", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => "una sola"})

    assert %{"data" => [%{"index" => 0}]} = json_response(conn, 200)
  end

  test "embeddings 400 without input", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name})

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "embeddings 400 model_type_mismatch against an llm model", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => "x"})

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "chat completions 400 model_type_mismatch against an embedding model", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "GET /v1/models includes model_type", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"data" => models} = json_response(conn, 200)
    entry = Enum.find(models, &(&1["id"] == model.name))
    assert entry["model_type"] == "embedding"
  end

  ## Las seis capacidades ruteadas por path #####################################
  #
  # One test per route: the gateway's public segment must land upstream as
  # base_url + the path `ProviderPaths` resolves for that service, the body
  # travels untouched, and the log row is labelled with the service key the
  # Capacidades modal uses (not with the route's name).

  test "POST /v1/rerank lands on base_url + /rerank", %{conn: conn} do
    conn =
      assert_service_route(conn, "/v1/rerank", "/rerank", "rerank", %{
        "query" => "hola",
        "documents" => ["uno", "dos"]
      })

    assert [%{"relevance_score" => 0.91}] = json_body(conn)["results"]
  end

  test "POST /v1/audio/transcriptions lands on base_url + /audio/transcriptions", %{conn: conn} do
    conn =
      assert_service_route(conn, "/v1/audio/transcriptions", "/audio/transcriptions", "stt", %{
        "input" => "audio"
      })

    assert json_body(conn)["text"] == "hola mundo"
  end

  test "POST /v1/audio/speech lands on base_url + /audio/speech", %{conn: conn} do
    conn =
      assert_service_route(conn, "/v1/audio/speech", "/audio/speech", "tts", %{"input" => "hola"})

    assert json_body(conn)["audio"] == "SUQzBAAAAAA"
  end

  test "POST /v1/videos lands on base_url + /videos", %{conn: conn} do
    conn = assert_service_route(conn, "/v1/videos", "/videos", "video", %{"prompt" => "un gato"})

    assert json_body(conn)["id"] == "video-job-1"
  end

  test "POST /v1/music/generations lands on base_url + /music/generations", %{conn: conn} do
    conn =
      assert_service_route(conn, "/v1/music/generations", "/music/generations", "music", %{
        "prompt" => "cumbia"
      })

    assert json_body(conn)["id"] == "music-1"
  end

  test "POST /v1/images/generations lands on base_url + /images/generations", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert %{"data" => [%{"b64_json" => "aW1n"}]} = json_response(conn, 200)
    assert_receive {:provider_request_path, "/images/generations"}
  end

  # An override saved from the Capacidades modal is the ONLY source of the
  # upstream path: it wins over the generic default of the service.
  test "an operator override on the provider row beats the generic default", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{path_overrides: %{"video" => "/custom/videos"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/videos", %{"model" => model.name, "prompt" => "un perro"})

    assert json_response(conn, 200)
    assert_receive {:provider_request_path, "/custom/videos"}
  end

  # The image API reports its tokens as `input_tokens`/`output_tokens`: they
  # must drive the cost exactly like a chat usage object would.
  test "images: the image API's token names drive the cost", %{conn: conn} do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } = proxy_fixture(%{credit_units: 100})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        input_cost_per_million: "1.00",
        output_cost_per_million: "2.00"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert json_response(conn, 200)

    # 100 in × $1/M + 200 out × $2/M = 0.0005
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000500"]
    assert %{consumed_micro: 500} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "image"
    assert log.prompt_tokens == 100
    assert log.completion_tokens == 200
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000500"))
  end

  # A service whose upstream reports no usage at all (video answers with a job
  # id): the request's own text is estimated, so manual pricing still books
  # something — and with no manual pricing the cost is the honest $0.
  test "video: no upstream usage falls back to the estimate over the request", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/videos", %{"model" => model.name, "prompt" => "un gato que baila"})

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0"]

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "video"
    assert log.prompt_tokens > 0
    assert log.completion_tokens == 0
  end

  ## Media passthrough (multipart in, binary out) ##############################
  #
  # The canonical stt call is `multipart/form-data`, and a tts upstream may
  # answer with audio bytes. Both are transport, not routing: the bytes must
  # cross the gateway untouched. See `TokengateWeb.Plugs.MediaBodyParser`.

  test "multipart /v1/audio/transcriptions reaches the upstream byte-for-byte", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture()
    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"

    # The wire saw the client's exact bytes and its original content-type —
    # the boundary included, or the upstream could not parse the body.
    assert_receive {:provider_raw_body, ^body, headers}
    assert {"content-type", "multipart/form-data; boundary=#{@boundary}"} in headers

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "stt"
    assert log.status_code == 200
  end

  test "two different multipart uploads are not one cache entry", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    # Same model, same form field names, different FILE BYTES: the response
    # cache hashes the parsed payload (which cannot carry the file), so a
    # cached hit here would answer the second upload with the first's result.
    first = multipart_body(model.name, "uno.wav")
    second = multipart_body(model.name, "dos.wav")

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", first)

    assert json_response(conn, 200)
    assert_receive {:provider_raw_body, ^first, _headers}

    conn =
      conn
      |> recycle()
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", second)

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cache") == []
    assert_receive {:provider_raw_body, ^second, _headers}
  end

  test "a binary upstream response reaches the client with its content-type", %{conn: conn} do
    %{token: token, model: model, member: member} =
      proxy_fixture(%{path_overrides: %{"tts" => "/binary-speech"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{"model" => model.name, "input" => "hola"})

    # The bytes, not a JSON wrapper: `json/1` would have sent `{}`.
    assert conn.status == 200
    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x00>>
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"

    # The cost header survives the binary path (no upstream usage and no
    # manual pricing: the honest $0).
    assert get_resp_header(conn, "x-tokengate-cost") == ["0"]

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "tts"
    assert log.status_code == 200
  end

  # A binary answer can still report its cost — LiteLLM proxies put it in a
  # response HEADER, and there is no JSON body to read it from.
  test "a binary upstream response still books the header-reported cost", %{conn: conn} do
    %{
      token: token,
      model: model,
      member: member
    } = proxy_fixture(%{credit_units: 100, path_overrides: %{"tts" => "/costly-binary-speech"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{"model" => model.name, "input" => "hola"})

    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x01>>
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000420"]

    assert %{consumed_micro: 420} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "tts"
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000420"))
  end

  # A tts client asks for audio, not JSON: the old `plug :accepts, ["json"]`
  # in the proxy pipeline refused it with a 406 before the controller ran.
  # The proxy mirrors the upstream's answer, so no negotiation happens here.
  test "an audio Accept header is not refused with 406", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{path_overrides: %{"tts" => "/binary-speech"}})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("accept", "audio/mpeg")
      |> post(~p"/v1/audio/speech", %{"model" => model.name, "input" => "hola"})

    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x00>>
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"
  end

  # The operator's override is the path the raw multipart body must reach:
  # the capture is transport, the path is routing — both have to line up.
  test "multipart passthrough honours the operator's path override", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{path_overrides: %{"stt" => "/custom/transcriptions"}})

    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)
    assert_receive {:provider_request_path, "/custom/transcriptions"}
    assert_receive {:provider_raw_body, ^body, _headers}
  end

  # Drives one of the six services end to end and returns the conn: the
  # fixture's provider points at the test server, so the path the wire saw is
  # what `ProviderPaths` resolved for the service.
  defp assert_service_route(conn, gateway, upstream_path, request_type, body) do
    %{token: token, model: model, member: member} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(gateway, Map.merge(%{"model" => model.name}, body))

    assert json_response(conn, 200)

    assert_receive {:provider_request_path, ^upstream_path}
    assert_receive {:provider_request, received}

    # The client's own fields travel untouched; the model is rewritten to the
    # provider's own id.
    Enum.each(body, fn {key, value} -> assert received[key] == value end)
    assert received["model"] =~ "gpt-4o-real"

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == request_type
    assert log.status_code == 200

    conn
  end

  defp json_body(conn), do: json_response(conn, 200)

  # ---------------------------------------------------------------------------
  # P2 — el gate por sujeto: 0 es CERO, unlimited_spend explícito pasa
  # ---------------------------------------------------------------------------

  describe "gate por sujeto (límite mensual + top-ups)" do
    test "límite 0 (cero) bloquea con 402 y código propio", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{credit_units: 0})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 402)["error"]["code"] == "budget_exceeded"
      refute json_response(conn, 402)["error"]["message"] =~ "Global"
    end

    test "sin límite, sin ilimitado y sin top-ups: 402 con código no_credit", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{blocked: true})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      body = json_response(conn, 402)
      assert body["error"]["code"] == "no_credit"
      # Copy propio: NO comparte el mensaje del límite agotado ni el del cap global.
      refute body["error"]["message"] =~ "Monthly"
      refute body["error"]["message"] =~ "Global"
    end

    test "unlimited_spend pasa aunque no haya límite", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{unlimited: true})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)
    end

    test "límite agotado + top-up vigente: el request pasa y se debita el top-up", %{conn: conn} do
      %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 0})

      {:ok, topup} =
        Tokengate.Credits.Topups.create(%{"user_id" => member.user_id, "amount_usd" => "50.00"})

      # El límite es 0 (cero): sin top-up sería 402. Con top-up vigente el
      # request pasa y el log registra QUÉ se debitó.
      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)
      assert %{success: 1} = Oban.drain_queue(queue: :logs)

      # El log asentado por ESTE request: el único con el monto exacto.
      log =
        Repo.one(
          from l in RequestLog,
            where: l.group_member_id == ^member.id,
            where: l.provider_cost_usd == ^Decimal.new("0.000150"),
            order_by: [desc: l.inserted_at],
            limit: 1
        )

      assert log.credit_topup_id == topup.id
      assert %{consumed_micro: 150} = Budgets.topup_spend(topup.id)
    end

    test "el 402 del cap global NO comparte copy con el del sujeto", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{unlimited: true})
      {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => "0.000001"})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      body = json_response(conn, 402)
      assert body["error"]["message"] =~ "Global"
      refute body["error"]["message"] =~ "No spending path"
    end
  end
end
