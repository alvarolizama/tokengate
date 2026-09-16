defmodule TokengateWeb.ServiceStatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "sstats-#{u}@example.com",
        name: "S #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp service_fixture do
    {:ok, service} =
      Accounts.create_service(%{
        name: "Svc Stats #{unique()}",
        concurrency_limit: 5,
        rpm_limit: 60
      })

    service
  end

  defp log_for(service, attrs) do
    Logs.log_request(
      Map.merge(
        %{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o-svc",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.001"),
          latency_ms: 300
        },
        attrs
      )
    )
  end

  describe "auth" do
    test "unauthenticated visitors are redirected to /login", %{conn: conn} do
      service = service_fixture()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, ~p"/stats/services/#{service.id}")
    end

    test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
      service = service_fixture()
      %{user: regular, password: password} = register("user")
      conn = login(conn, regular, password)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/stats/services/#{service.id}")
    end
  end

  describe "render" do
    test "admin sees the service header (name + unlimited sub label)", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ service.name
      assert html =~ "Ilimitado"
    end

    test "admin sees the service's logs", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _} = log_for(service, %{model_requested: "gpt-4o-svc", status_code: 200})
      {:ok, _} = log_for(service, %{model_requested: "gpt-4o-svc", status_code: 503})

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ "gpt-4o-svc"
      assert html =~ "200"
      assert html =~ "503"
    end

    test "logs from another service are not shown", %{conn: conn} do
      service = service_fixture()
      other = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _} = log_for(service, %{model_requested: "only-this-one"})
      {:ok, _} = log_for(other, %{model_requested: "other-service-model"})

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ "only-this-one"
      refute html =~ "other-service-model"
    end
  end

  describe "access from the services list" do
    test "services_live has a stats link for every service", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/access/services")
      assert html =~ ~s(id="stats-#{service.id}")
    end
  end
end
