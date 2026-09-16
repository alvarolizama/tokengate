defmodule TokengateWeb.CoreComponentsTest do
  @moduledoc """
  The generic `<.input>` branch is used by every text-like field in the app
  (paths modal, forms, filters). It renders `placeholder` — the sibling
  `datalist` branch does too — so a caller's placeholder is never dropped in
  silence.
  """

  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias TokengateWeb.CoreComponents

  test "input/1 renders the placeholder on a text input" do
    html =
      render_component(&CoreComponents.input/1, %{
        id: "paths_chat",
        name: "paths[chat]",
        type: "text",
        value: "",
        placeholder: "/chat/completions"
      })

    assert html =~ ~s{placeholder="/chat/completions"}
  end

  test "input/1 omits the placeholder attribute when there is none" do
    html =
      render_component(&CoreComponents.input/1, %{
        id: "name",
        name: "name",
        type: "text",
        value: ""
      })

    refute html =~ "placeholder="
  end

  test "input/1 renders the placeholder on a textarea" do
    html =
      render_component(&CoreComponents.input/1, %{
        id: "guard_rails",
        name: "guard_rails",
        type: "textarea",
        value: "",
        placeholder: "Ej: Responde siempre en español..."
      })

    assert html =~ ~s{placeholder="Ej: Responde siempre en español..."}
  end
end
