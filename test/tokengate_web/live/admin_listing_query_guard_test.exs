defmodule TokengateWeb.AdminListingQueryGuardTest do
  @moduledoc """
  Guard for the admin listings' query shape: a WARM mount of `/access/users`
  and `/access/services` must not touch `request_logs` at all.

  Every aggregate those pages render (month spend, limit spend, lifetime total,
  30d service stats, credits) is backed by `DashboardCache`, so a second mount
  inside the TTL window is pure hits. If someone reinstates a per-render
  aggregate — the exact shape these pages had before (18 queries on users,
  including every group member row and six hybrid scans) — this test goes red
  without pinning any absolute query count.

  It also mounts with 2 and with 8 rows of data: the count must not move with
  volume, which is what catches a reintroduced N+1.
  """

  use TokengateWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register_admin do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "guard-#{u}@example.com",
        name: "Guard #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp seed_user_with_spend do
    u = unique()
    {:ok, group} = Accounts.create_group(%{name: "Guard Group #{u}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "guarded-#{u}@example.com",
        name: "Guarded #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        user_id: user.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new("0.50")
      })

    user
  end

  defp seed_service_with_spend do
    u = unique()
    {:ok, service} = Accounts.create_service(%{name: "Guard Service #{u}"})

    {:ok, group} = Accounts.create_group(%{name: "Guard Svc Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "guarded-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{"user_id" => owner.id, "group_id" => group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Guard Prov #{u}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        service_id: service.id,
        provider_id: provider.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new("0.25")
      })

    service
  end

  # Warm mount (the aggregates land in DashboardCache), then measure the NEXT
  # mount: same TTL window, so every aggregate must be a hit.
  defp warm_mount_request_log_queries(conn, path) do
    {:ok, _view, _html} = live(conn, path)
    hook = {__MODULE__, make_ref()}
    counter = :counters.new(1, [:atomics])
    :counters.put(counter, 1, 0)

    :telemetry.attach(
      hook,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "request_logs", do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      {:ok, _view, _html} = live(conn, path)
    after
      :telemetry.detach(hook)
    end

    :counters.get(counter, 1)
  end

  test "/access/services: un mount caliente no toca request_logs", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)

    for _ <- 1..2, do: seed_service_with_spend()
    small = warm_mount_request_log_queries(conn, ~p"/access/services")

    for _ <- 1..6, do: seed_service_with_spend()
    large = warm_mount_request_log_queries(conn, ~p"/access/services")

    assert small == 0
    assert large == 0
  end

  test "/access/users: un mount caliente no toca request_logs", %{conn: conn} do
    %{user: admin, password: password} = register_admin()
    conn = login(conn, admin, password)

    for _ <- 1..2, do: seed_user_with_spend()
    small = warm_mount_request_log_queries(conn, ~p"/access/users")

    for _ <- 1..6, do: seed_user_with_spend()
    large = warm_mount_request_log_queries(conn, ~p"/access/users")

    assert small == 0
    assert large == 0
  end

  # Sanity check of the guard itself: a raw aggregate on the same page WOULD
  # count, so a zero above means "served from the cache / counters", not "the
  # telemetry hook is broken".
  test "el hook cuenta de verdad las queries a request_logs", %{conn: _conn} do
    seed_user_with_spend()

    hook = {__MODULE__, make_ref()}
    counter = :counters.new(1, [:atomics])

    :telemetry.attach(
      hook,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "request_logs", do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      Logs.total_spend_by_service(from: DateTime.add(DateTime.utc_now(), -86_400, :second))
    after
      :telemetry.detach(hook)
    end

    assert Repo.one(from(l in "request_logs", select: count(l.id))) > 0
    assert :counters.get(counter, 1) >= 1
  end
end
