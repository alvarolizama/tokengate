defmodule TokengateWeb.SmartRouterShadowProxyTest do
  @moduledoc """
  End-to-end coverage of the Shadow wiring in the proxy (S4/Track 2A).

  A live `"model": "router"` request must (1) persist the configuration
  VERSION that decided, (2) hand the Shadow evaluator the pre-generated
  `(request_log_id, request_inserted_at)` pair, the client's original body, the
  Default's decision and the real usage, and (3) evaluate every
  `shadow_enabled` version asynchronously — writing `router_shadow_evaluations`
  rows that never touch the log's accounting. With no shadow enabled, nothing
  is written.
  """

  use TokengateWeb.ConnCase, async: false

  use Oban.Testing, repo: Tokengate.Repo

  import Ecto.Query, only: [from: 2]

  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Logs.{RequestLog, WriteWorker}
  alias Tokengate.SmartRouter

  alias Tokengate.SmartRouter.{
    Config,
    Rule,
    ShadowEvaluation,
    ShadowEvaluator,
    UseCase,
    UseCaseModel
  }

  # ---------------------------------------------------------------------------
  # Fake upstream
  # ---------------------------------------------------------------------------

  defmodule UpstreamPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.path_info do
        ["chat", "completions" | _] ->
          json(conn, 200, chat_ok())

        _ ->
          json(conn, 404, %{"error" => %{"message" => "not found"}})
      end
    end

    defp chat_ok do
      %{
        "id" => "chatcmpl-shadow",
        "object" => "chat.completion",
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}
        ],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30}
      }
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end

  setup do
    port = Tokengate.TestPort.free_port()
    :persistent_term.put({__MODULE__, :port}, port)
    start_supervised!({Bandit, plug: UpstreamPlug, scheme: :http, ip: :loopback, port: port})

    # The Shadow evaluation runs in a Task spawned by the request process:
    # it needs the sandbox's connection to read the version and write its row.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  defp upstream_url do
    "http://localhost:#{:persistent_term.get({__MODULE__, :port})}"
  end

  defp create_lane(name, prices) do
    {:ok, provider} =
      Providers.create_provider(%{name: "P #{name}", base_url: upstream_url()})

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-#{name}"
      })

    {:ok, model} =
      Providers.create_model(%{name: name, model_type: "llm", context_window: 128_000})

    {:ok, _model_provider} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "upstream-#{name}",
        priority: 1,
        input_cost_per_million: Decimal.new(prices.input),
        output_cost_per_million: Decimal.new(prices.output)
      })

    model
  end

  defp member_fixture do
    u = unique()

    {:ok, group} =
      Accounts.create_group(%{
        name: "Shadow Proxy Group #{u}",
        default_rpm_limit: 600,
        default_concurrency_limit: 10,
        router_enabled: true,
        unlimited_spend: true
      })

    {:ok, user} =
      Accounts.register_user(%{
        email: "shadow-proxy-#{u}@example.com",
        name: "Shadow Proxy #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{group: group, user: user, member: member, token: token}
  end

  defp enable_router(attrs \\ %{}) do
    config =
      Config.ensure!()
      |> Config.changeset(Map.merge(%{enabled: true}, attrs))
      |> Repo.update!()

    SmartRouter.invalidate()
    config
  end

  defp create_use_case(config_id, attrs, bindings) do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(
        Map.merge(
          %{
            router_config_id: config_id,
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

    for binding <- bindings do
      {:ok, _row} =
        %UseCaseModel{}
        |> UseCaseModel.changeset(Map.merge(%{router_use_case_id: use_case.id}, binding))
        |> Repo.insert()
    end

    SmartRouter.invalidate()
    use_case
  end

  defp create_shadow_version(attrs) do
    {:ok, version} =
      %Config{}
      |> Config.changeset(
        Map.merge(
          %{
            name: "Shadow #{unique()}",
            enabled: true,
            shadow_enabled: true,
            shadow_sample_pct: 100
          },
          attrs
        )
      )
      |> Repo.insert()

    SmartRouter.invalidate()
    version
  end

  defp authed_conn(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp chat_body(text) do
    %{
      "model" => "router",
      "messages" => [%{"role" => "user", "content" => text}]
    }
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

  defp shadow_rows do
    Repo.all(from e in ShadowEvaluation, order_by: e.inserted_at)
  end

  ## Tests #####################################################################

  test "persists router_config_id and evaluates the shadow asynchronously", %{conn: conn} do
    %{token: token, member: member} = member_fixture()

    primary = create_lane("shadow-primary-#{unique()}", %{input: "1", output: "2"})
    shadow_target = create_lane("shadow-target-#{unique()}", %{input: "3", output: "6"})

    default = enable_router()

    # The Default serves `primary`; the shadow version would serve `shadow_target`
    # on a lower tier — exactly the discrepancy the comparison exists to show.
    create_use_case(default.id, %{}, [
      %{target_model_id: primary.id, effort_tier: "high"}
    ])

    version = create_shadow_version(%{})

    create_use_case(version.id, %{}, [
      %{target_model_id: shadow_target.id, effort_tier: "low"}
    ])

    Phoenix.PubSub.subscribe(Tokengate.PubSub, ShadowEvaluator.topic())

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("shadow request #{unique()}"))

    assert json_response(conn, 200)

    # The evaluator is dispatched AFTER the log job and BEFORE the client's
    # response is finished: wait for its own event instead of sleeping.
    assert_receive {:shadow_evaluated, request_log_id, [evaluation]}, 2_000

    assert evaluation.shadow_config_id == version.id
    assert evaluation.default_config_id == default.id
    assert evaluation.request_log_id == request_log_id

    # The Default side is what actually served.
    assert evaluation.default_model_id == primary.id
    assert evaluation.default_effort_tier == "high"

    # The Shadow side is the other version's destination, priced with the REAL
    # tokens of this request: 20 * 3/1M + 10 * 6/1M = 0.00012.
    assert evaluation.model_id == shadow_target.id
    assert evaluation.effort_tier == "low"
    assert Decimal.equal?(evaluation.estimated_served_cost_usd, Decimal.new("0.00012"))
    assert evaluation.matches_default_model == false
    assert evaluation.matches_default_tier == false

    drain_logs()
    [log] = logs_for(member)

    # The very same pair the evaluator used identifies the durable log row.
    assert log.id == request_log_id
    assert log.inserted_at == evaluation.request_inserted_at
    # The version that decided is on the row.
    assert log.router_config_id == default.id
    assert log.model_id == primary.id
    # Both sides of the comparison price the same request.
    assert Decimal.equal?(evaluation.default_served_cost_usd, log.provider_cost_usd)

    # The shadow wrote its own table only: the accounting row is untouched.
    assert [%ShadowEvaluation{}] = shadow_rows()
    assert Repo.aggregate(RequestLog, :count, :id) == 1
  end

  test "a user_ids rule fires from the context the proxy builds", %{conn: conn} do
    %{token: token, member: member} = member_fixture()

    other = create_lane("user-rule-other-#{unique()}", %{input: "1", output: "1"})
    forced = create_lane("user-rule-forced-#{unique()}", %{input: "1", output: "1"})

    default = enable_router()

    create_use_case(default.id, %{key: "coding", priority: 10}, [
      %{target_model_id: other.id, effort_tier: "any"}
    ])

    create_use_case(default.id, %{key: "finance", priority: 20}, [
      %{target_model_id: forced.id, effort_tier: "any"}
    ])

    {:ok, _rule} =
      %Rule{}
      |> Rule.changeset(%{
        router_config_id: default.id,
        name: "finance for this user #{unique()}",
        action: "force_use_case",
        target_use_case_keys: ["finance"],
        match_conditions: %{"user_ids" => [member.user_id]}
      })
      |> Repo.insert()

    SmartRouter.invalidate()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("route by user #{unique()}"))

    assert json_response(conn, 200)

    drain_logs()
    [log] = logs_for(member)

    # The rule matched ONLY because `router_decision_context/2` carries the
    # user behind the member.
    assert log.router_use_case_key == "finance"
    assert log.model_id == forced.id
    assert log.router_decision_source in ["rule", "fast_path"]
  end

  test "writes no evaluation when no version is a shadow", %{conn: conn} do
    %{token: token, member: member} = member_fixture()

    primary = create_lane("shadow-off-#{unique()}", %{input: "1", output: "2"})
    default = enable_router()
    create_use_case(default.id, %{}, [%{target_model_id: primary.id, effort_tier: "high"}])

    # A candidate version that is NOT under evaluation.
    {:ok, _draft} =
      %Config{}
      |> Config.changeset(%{name: "Draft #{unique()}", enabled: true})
      |> Repo.insert()

    SmartRouter.invalidate()
    assert SmartRouter.shadow_configs() == []

    Phoenix.PubSub.subscribe(Tokengate.PubSub, ShadowEvaluator.topic())

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("no shadow #{unique()}"))

    assert json_response(conn, 200)

    drain_logs()
    [log] = logs_for(member)

    assert log.router_config_id == default.id
    assert shadow_rows() == []
    refute_receive {:shadow_evaluated, _, _}, 300
  end
end
