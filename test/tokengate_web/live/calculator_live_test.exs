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
    {:ok, alias_} =
      Providers.create_model_alias(%{
        name: "calc-market-#{unique()}",
        context_window: 128_000,
        model_type: "llm",
        market_input_price_per_1m: "1.25",
        market_output_price_per_1m: "10",
        market_cache_price_per_1m: "0.125"
      })

    alias_
  end

  test "admin sees calculator page with form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/calculator")

    assert html =~ "Calculadora de Costos"
    assert html =~ "Entrada $/1M"
    assert html =~ "Cache $/1M"
    assert html =~ "Salida $/1M"
  end

  test "regular user is redirected from calculator", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/dashboard/calculator")
    assert to =~ "/dashboard"
  end

  test "selecting a model with market prices shows the market line", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    alias_ = market_alias_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/calculator")

    html =
      view
      |> form("#calculator-form", %{
        model_id: alias_.id,
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
    alias_ = market_alias_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/dashboard/calculator")

    html =
      view
      |> form("#calculator-form", %{
        model_id: alias_.id,
        period: "7d",
        cost_input: "3.00",
        cost_cache: "0.30",
        cost_output: "15.00"
      })
      |> render_change()

    # The three spends render even with zero traffic in the period.
    assert html =~ "Gasto Real"
    assert html =~ "Gasto Estimado (custom)"
    assert html =~ "Estimado Mercado"

    # Custom inputs keep the submitted values.
    assert html =~ ~s(value="3.00")
    assert html =~ ~s(value="15.00")
  end

  test "market estimate card is hidden when the alias has no market prices", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, alias_} =
      Providers.create_model_alias(%{
        name: "calc-plain-#{unique()}",
        context_window: 128_000,
        model_type: "llm"
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/calculator")

    html =
      view
      |> form("#calculator-form", %{model_id: alias_.id, period: "7d"})
      |> render_change()

    assert html =~ "Gasto Estimado (custom)"
    refute html =~ "Estimado Mercado"
  end
end
