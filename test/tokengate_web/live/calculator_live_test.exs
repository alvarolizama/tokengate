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

  defp model_fixture do
    {:ok, model_} =
      Providers.create_model(%{
        name: "calc-model-#{unique()}",
        context_window: 128_000,
        model_type: "llm"
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
    _ = view
  end

  test "regular user is redirected from calculator", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/calculator")
    assert to =~ "/dashboard"
  end

  test "selecting a model renders the real and custom estimate cards", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
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

    # Ambas comparativas renderizan aunque no haya tráfico en el periodo.
    assert has_element?(view, "#calc-real")
    assert has_element?(view, "#calc-estimated")

    # Los inputs custom conservan lo enviado.
    assert html =~ ~s(value="3.00")
    assert html =~ ~s(value="15.00")
  end

  test "the market estimate is gone from the calculator", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    model_ = model_fixture()
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/calculator")

    html =
      view
      |> form("#calculator-form", %{model_id: model_.id, period: "7d"})
      |> render_change()

    refute has_element?(view, "#calc-market")
    refute has_element?(view, "#use-market-prices")
    refute html =~ "Estimado Mercado"
    refute html =~ "Mercado:"
  end
end
