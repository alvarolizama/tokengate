defmodule Tokengate.Observability.WebhookWorkerTest do
  @moduledoc """
  Integration tests for `Tokengate.Observability.WebhookWorker` against a
  live Bandit server: HTTP POST delivery, HMAC signature verification,
  custom header forwarding, OTLP payload validity, retry semantics
  (200 → :ok, 400 → discard, 500 → error), and dispatch/1 enqueuing.
  """

  use Tokengate.DataCase, async: false
  use Oban.Testing, repo: Tokengate.Repo

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Observability
  alias Tokengate.Observability.WebhookWorker

  @port 41334

  # ---------------------------------------------------------------------------
  # Bandit test plug — captures request details and routes by marker path
  # ---------------------------------------------------------------------------

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        signature = get_req_header(conn, "x-tokengate-signature")
        content_type = get_req_header(conn, "content-type")
        custom = get_req_header(conn, "x-custom-header")

        send(
          pid,
          {:captured,
           %{
             method: conn.method,
             path: conn.request_path,
             body: body,
             signature: signature,
             content_type: content_type,
             custom_header: custom
           }}
        )
      end

      route(conn, body)
    end

    defp route(conn, _body) do
      cond do
        "bad" in conn.path_info ->
          json(conn, 400, %{"error" => "bad request"})

        "broken" in conn.path_info ->
          json(conn, 500, %{"error" => "boom"})

        true ->
          json(conn, 200, %{"ok" => true})
      end
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures — real DB records via contexts
  # ---------------------------------------------------------------------------

  defp team_fixture do
    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Platform Team",
        "default_daily_budget_usd" => "100.00",
        "default_monthly_budget_usd" => "1000.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      })

    team
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "user#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      })

    user
  end

  defp team_member_fixture do
    team = team_fixture()
    user = user_fixture()

    {:ok, team_member} =
      Accounts.create_team_member(%{
        "user_id" => user.id,
        "team_id" => team.id
      })

    team_member
  end

  defp destination_fixture(url, attrs \\ %{}) do
    {:ok, dest} =
      Observability.create_destination(
        Map.merge(
          %{
            "name" => "OTLP Collector",
            "type" => "otlp_webhook",
            "url" => url,
            "privacy_mode" => "metadata_only"
          },
          attrs
        )
      )

    dest
  end

  defp log_fixture(team_member_id, attrs \\ %{}) do
    {:ok, log} =
      Logs.log_request(
        Map.merge(
          %{
            team_member_id: team_member_id,
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
      )

    log
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    :persistent_term.put({TestPlug, :test_pid}, self())
    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})
    :ok
  end

  defp base_url(marker \\ ""), do: "http://localhost:#{@port}#{marker}"

  # ---------------------------------------------------------------------------
  # perform/1 — HTTP delivery
  # ---------------------------------------------------------------------------

  describe "perform/1 — 200 success" do
    test "returns :ok on 2xx" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url())

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      assert :ok = WebhookWorker.perform(job)
    end

    test "sends valid OTLP payload" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url())

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      :ok = WebhookWorker.perform(job)

      assert_receive {:captured, %{body: raw_body}}

      payload = Jason.decode!(raw_body)
      assert Map.has_key?(payload, "resourceSpans")
      [rs] = payload["resourceSpans"]
      [ss] = rs["scopeSpans"]
      assert ss["scope"]["name"] == "tokengate"
      assert length(ss["spans"]) == 1
    end

    test "HMAC signature verifies against body" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url())

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      :ok = WebhookWorker.perform(job)

      assert_receive {:captured, %{body: body, signature: [sig]}}

      # Verify the signature format
      assert String.starts_with?(sig, "sha256=")

      # Recompute HMAC and compare
      secret = Application.get_env(:tokengate, :webhook_secret, "tokengate-dev-secret")
      expected_mac = :crypto.mac(:hmac, :sha256, secret, body)
      expected_sig = "sha256=" <> Base.encode16(expected_mac, case: :lower)

      assert sig == expected_sig
    end

    test "forwards custom destination headers" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)

      dest =
        destination_fixture(base_url(), %{"headers" => %{"X-Custom-Header" => "my-value"}})

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      :ok = WebhookWorker.perform(job)

      assert_receive {:captured, %{custom_header: [val]}}
      assert val == "my-value"
    end

    test "content-type is application/json" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url())

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      :ok = WebhookWorker.perform(job)

      assert_receive {:captured, %{content_type: [ct]}}
      assert ct == "application/json"
    end
  end

  describe "perform/1 — retry semantics" do
    test "400 → {:discard, _}" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url("/bad"))

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      assert {:discard, _} = WebhookWorker.perform(job)
    end

    test "500 → {:error, _}" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)
      dest = destination_fixture(base_url("/broken"))

      job = %Oban.Job{
        args: %{"destination_id" => dest.id, "request_log_ids" => [to_string(log.id)]}
      }

      assert {:error, _} = WebhookWorker.perform(job)
    end

    test "nonexistent log ids → {:discard, _}" do
      _tm = team_member_fixture()
      dest = destination_fixture(base_url())

      # Use a valid UUID format that doesn't exist in the DB
      fake_id = Ecto.UUID.generate()
      job = %Oban.Job{args: %{"destination_id" => dest.id, "request_log_ids" => [fake_id]}}
      assert {:discard, _} = WebhookWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch/1
  # ---------------------------------------------------------------------------

  describe "dispatch/1" do
    test "enqueues one job per destination" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)

      dest1 = destination_fixture(base_url(), %{"name" => "Collector 1"})
      dest2 = destination_fixture(base_url(), %{"name" => "Collector 2"})

      assert {:ok, 2} = WebhookWorker.dispatch(log)

      assert_enqueued(
        worker: WebhookWorker,
        args: %{"destination_id" => dest1.id, "request_log_ids" => [to_string(log.id)]}
      )

      assert_enqueued(
        worker: WebhookWorker,
        args: %{"destination_id" => dest2.id, "request_log_ids" => [to_string(log.id)]}
      )
    end

    test "returns {:ok, 0} when no destinations configured" do
      tm = team_member_fixture()
      log = log_fixture(tm.id)

      assert {:ok, 0} = WebhookWorker.dispatch(log)
    end

    test "handles nil team_member_id gracefully" do
      log = %Tokengate.Logs.RequestLog{team_member_id: nil}
      assert {:ok, 0} = WebhookWorker.dispatch(log)
    end
  end
end
