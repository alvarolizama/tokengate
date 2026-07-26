defmodule TokengateWeb.PricingLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "pricing-#{u}@example.com",
        name: "User #{u}",
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

  defp create_org do
    u = unique()
    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})
    org
  end

  defp create_provider(billing_type) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Provider #{u}",
        base_url: "http://localhost:1",
        billing_type: billing_type
      })

    provider
  end

  defp create_alias(org) do
    u = unique()

    {:ok, alias_record} =
      Providers.create_model_alias(%{
        organization_id: org.id,
        name: "alias-#{u}",
        display_name: "Alias #{u}",
        market_input_price_per_1m: "1.50",
        market_output_price_per_1m: "3.00",
        context_window: 128_000,
        routing_strategy: "priority"
      })

    alias_record
  end

  defp create_alias_provider(model_alias, provider) do
    u = unique()

    {:ok, ap} =
      Providers.create_alias_provider(%{
        model_alias_id: model_alias.id,
        provider_id: provider.id,
        provider_model: "gpt-4o-#{u}",
        priority: 1,
        enabled: true
      })

    ap
  end

  defp create_pricing(ap, attrs \\ %{}) do
    {:ok, pricing} =
      Providers.create_model_pricing(
        Map.merge(
          %{
            alias_provider_id: ap.id,
            input_price_per_1m: "2.50",
            output_price_per_1m: "5.00",
            effective_from: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    pricing
  end

  # -- Permissions ----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/pricing")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/pricing")
  end

  test "admin can mount the pricing page", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/pricing")

    assert html =~ "Pricing"
    assert has_element?(view, "#alias-providers")
  end

  # -- Empty state ----------------------------------------------------------

  test "shows empty state when no pay-per-token alias providers exist", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/dashboard/pricing")

    assert html =~ "No hay proveedores pay-per-token configurados"
  end

  # -- Pricing CRUD ---------------------------------------------------------

  test "admin can create a new pricing entry", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider("pay_per_token")
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/pricing")

    view |> element("#new-pricing-#{ap.id}") |> render_click()

    assert has_element?(view, "#pricing-form")

    html =
      view
      |> form("#pricing-form", %{
        model_pricing: %{
          alias_provider_id: ap.id,
          input_price_per_1m: "3.50",
          output_price_per_1m: "7.00",
          effective_from: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
      |> render_submit()

    assert html =~ "Pricing creado"
    assert html =~ "3.50"
  end

  test "admin can edit an existing pricing entry", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider("pay_per_token")
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    pricing = create_pricing(ap)
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/pricing")

    view |> element("#edit-pricing-#{pricing.id}") |> render_click()

    assert has_element?(view, "#pricing-form")

    html =
      view
      |> form("#pricing-form", %{
        model_pricing: %{
          alias_provider_id: ap.id,
          input_price_per_1m: "9.99",
          output_price_per_1m: "19.99",
          effective_from: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
      |> render_submit()

    assert html =~ "Pricing actualizado"
    assert html =~ "9.99"
  end

  test "admin can delete a pricing entry", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider("pay_per_token")
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    pricing = create_pricing(ap)
    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/pricing")
    assert html =~ "2.50"

    view |> element("#delete-pricing-#{pricing.id}") |> render_click()

    html = render(view)
    assert html =~ "Pricing eliminado"
    refute html =~ "2.50"
  end

  # -- Filtering: subscription providers excluded ---------------------------

  test "subscription providers are not shown in pricing page", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()

    # Create a subscription provider with an alias_provider
    sub_provider = create_provider("subscription")
    alias_record = create_alias(org)
    create_alias_provider(alias_record, sub_provider)

    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/pricing")

    # Should show empty state since no pay_per_token providers exist
    assert html =~ "No hay proveedores pay-per-token configurados"
    refute has_element?(view, "#new-pricing-")
  end

  test "pay_per_token providers with pricing show the pricing table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    org = create_org()
    provider = create_provider("pay_per_token")
    alias_record = create_alias(org)
    ap = create_alias_provider(alias_record, provider)
    create_pricing(ap, %{input_price_per_1m: "1.25", output_price_per_1m: "2.50"})

    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/dashboard/pricing")

    assert html =~ provider.name
    assert html =~ "1.25"
    assert html =~ "2.50"
  end
end
