defmodule TokengateWeb.PromptInspectorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Prompts.Cache}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "prompts-#{u}@example.com",
        name: "Prompts #{u}",
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

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/prompts")
  end

  test "non-admins cannot open the inspector", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/prompts")
  end

  test "modal stays open when a new prompt arrives while it is open", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/prompts")

    # Capture a prompt and let the stream insert land.
    entry = Cache.capture(%{messages: [%{"content" => "primer prompt"}]})
    _ = render(view)

    # Click the row to open the full-prompt modal.
    view |> element("tr[phx-value-id=\"#{entry.id}\"]") |> render_click()

    html = render(view)
    assert html =~ ~s(data-open="true")
    assert html =~ "primer prompt"

    # A new prompt is captured while the modal is open. Before the fix, this
    # repaint destroyed the <dialog> and closed the modal; the server must keep
    # @modal_prompt assigned so data-open stays "true" and the JS hook reopens it.
    Cache.capture(%{messages: [%{"content" => "segundo prompt"}]})
    html = render(view)

    assert html =~ ~s(data-open="true")
    assert html =~ "primer prompt"
  end

  test "stream limit does not crash when capturing > @max_rows prompts", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/prompts")

    # Capture @max_rows + 5 prompts to exceed the stream limit.
    total = 200 + 5

    Enum.each(1..total, fn i ->
      Cache.capture(%{messages: [%{"content" => "prompt #{i}"}]})
    end)

    html = render(view)

    # The live limit is client-side (LiveView JS). The server-rendered HTML
    # may still list all entries. We only assert that the view didn't crash
    # and the most-recent prompt is present.
    assert html =~ "prompt #{total}"
  end
end
