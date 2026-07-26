defmodule TokengateWeb.SubscriptionsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register_admin do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "admin-#{u}@example.com",
        name: "Admin #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp register_user do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: "user"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp create_provider do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Prov #{u}",
        base_url: "https://api-#{u}.example.com",
        billing_type: "subscription"
      })

    provider
  end

  defp create_subscription(provider, attrs \\ %{}) do
    {:ok, sub} =
      Providers.create_subscription(
        Map.merge(
          %{
            provider_id: provider.id,
            name: "Sub #{unique()}",
            cost: "20.00",
            billing_cycle: "monthly",
            start_date: Date.utc_today(),
            status: "active"
          },
          attrs
        )
      )

    sub
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/subscriptions")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register_user()

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/subscriptions")
  end

  test "admin sees providers and empty state", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/subscriptions")

    assert html =~ "Subscripciones"
    assert html =~ provider.name
    assert has_element?(view, "#subs-empty")
  end

  test "admin creates a subscription with cost and billing cycle", %{conn: conn} do
    provider = create_provider()
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/subscriptions")

    view |> element("#new-sub-#{provider.id}") |> render_click()
    assert has_element?(view, "#subscription-form")

    html =
      view
      |> form("#subscription-form",
        subscription: %{
          provider_id: provider.id,
          name: "OpenRouter Pro",
          cost: "20.00",
          billing_cycle: "monthly",
          start_date: Date.to_string(Date.utc_today()),
          billing_day: "15",
          status: "active"
        }
      )
      |> render_submit()

    assert html =~ "Subscripción creada."
    assert html =~ "OpenRouter Pro"
    assert html =~ "$20.00"
    assert html =~ "monthly"
    assert html =~ "Activa"
  end

  test "admin edits a subscription", %{conn: conn} do
    provider = create_provider()
    sub = create_subscription(provider)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/subscriptions")

    view |> element("#edit-sub-#{sub.id}") |> render_click()
    assert has_element?(view, "#subscription-form")

    html =
      view
      |> form("#subscription-form",
        subscription: %{name: "Sub Renombrada", cost: "99.50"}
      )
      |> render_submit()

    assert html =~ "Subscripción actualizada."
    assert html =~ "Sub Renombrada"
    assert html =~ "$99.50"
  end

  test "admin marks a subscription as exhausted", %{conn: conn} do
    provider = create_provider()
    sub = create_subscription(provider)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/subscriptions")

    html = view |> element("#exhaust-sub-#{sub.id}") |> render_click()

    assert html =~ "agotada"
    assert html =~ "Agotada"
  end

  test "admin cancels a subscription", %{conn: conn} do
    provider = create_provider()
    sub = create_subscription(provider)
    %{user: admin, password: password} = register_admin()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/subscriptions")

    html = view |> element("#cancel-sub-#{sub.id}") |> render_click()

    assert html =~ "Subscripción cancelada."
    assert html =~ "Cancelada"
    # Cancelled subs no longer show the action buttons
    refute has_element?(view, "#cancel-sub-#{sub.id}")
  end
end
