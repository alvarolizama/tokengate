defmodule TokengateWeb.CalculatorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.Providers

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "calc-#{u}@example.com",
        name: "Calc #{u}",
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

  defp market_alias_fixture do
    {:ok, model_} =
      Providers.create_model(%{
        name: "calc-market-#{unique()}",
        context_window: 128_000,
        model_type: "llm",
        market_input_price_per_1m: "1.25",
        market_output_price_per_1m: "10",
        market_cache_price_per_1m: "0.125"
      })

    model_
  end

  test "admin sees calculator page with form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/calculator")

    assert html =~ "Calculadora de Costos"
    assert html =~ "Precios custom"
    # Input groups: label + $ prefix + /1M suffix per price
    assert html =~ ~s(for="cost-input")
    assert html =~ "Entrada"
    assert html =~ "Cache"
    assert html =~ "Salida"
    assert html =~ "/1M"
    # Market shortcut disabled until a model with pricing is selected
    assert has_element?(view, "#use-market-prices[disabled]")
  end

  test "regular user is redirected from calculator", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/calculator")
    assert to =~ "/dashboard"
  end

  test "selecting a model with market prices shows the market line", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = market_alias_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{
        model_id: model_.id,
        period: "7d",
        cost_input: "3.00",
        cost_cache: "0.30",
        cost_output: "15.00"
      })
      |> render_change()

    # Market prices of the selected model, rendered as a single line.
    assert html =~ "Mercado: in $1.25 · cache $0.125 · out $10 /1M"
  end

  test "market estimate card renders alongside real and custom estimates", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = market_alias_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{
        model_id: model_.id,
        period: "7d",
        cost_input: "3.00",
        cost_cache: "0.30",
        cost_output: "15.00"
      })
      |> render_change()

    # The three spends render even with zero traffic in the period.
    assert has_element?(view, "#calc-real")
    assert has_element?(view, "#calc-estimated")
    assert has_element?(view, "#calc-market")

    # Custom inputs keep the submitted values.
    assert html =~ ~s(value="3.00")
    assert html =~ ~s(value="15.00")
  end

  test "market estimate card is hidden when the model has no market prices", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, model_} =
      Providers.create_model(%{
        name: "calc-plain-#{unique()}",
        context_window: 128_000,
        model_type: "llm"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{model_id: model_.id, period: "7d"})
      |> render_change()

    assert has_element?(view, "#calc-estimated")
    refute has_element?(view, "#calc-market")
    # Market shortcut stays disabled without market pricing
    assert has_element?(view, "#use-market-prices[disabled]")
  end

  test "use_market_prices fills the custom inputs with market prices", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = market_alias_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    view
    |> form("#calculator-form", %{model_id: model_.id, period: "7d"})
    |> render_change()

    # Button enabled now that market prices are available
    refute has_element?(view, "#use-market-prices[disabled]")

    html = view |> element("#use-market-prices") |> render_click()

    # Custom inputs now carry the market prices
    assert html =~ ~s(value="1.25")
    assert html =~ ~s(value="0.125")
    assert html =~ ~s(value="10")
  end
end
