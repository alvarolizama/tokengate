defmodule TokengateWeb.CalculatorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
end
