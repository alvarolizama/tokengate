defmodule TokengateWeb.CoreComponentsTest do
  @moduledoc """
  The generic `<.input>` branch is used by every text-like field in the app
  (paths modal, forms, filters). It renders `placeholder` — the sibling
  `datalist` branch does too — so a caller's placeholder is never dropped in
  silence.

  It also owns the one exception to `value`: a password input never renders it.
  Whatever the field holds at render time (a secret typed into an alta form, or
  the stored credential in an edit form) would otherwise sit in the DOM and in
  every LiveView diff.
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

  describe "password inputs" do
    test "input/1 never renders a password value" do
      html =
        render_component(&CoreComponents.input/1, %{
          id: "credential_api_key_encrypted",
          name: "credential[api_key_encrypted]",
          type: "password",
          value: "sk-live-super-secret-abcd"
        })

      assert html =~ ~s{type="password"}
      assert html =~ ~s{name="credential[api_key_encrypted]"}
      refute html =~ "sk-live-super-secret-abcd"
      refute html =~ "value="
    end

    test "input/1 keeps rendering text values next to it" do
      html =
        render_component(&CoreComponents.input/1, %{
          id: "name",
          name: "credential[name]",
          type: "text",
          value: "Producción"
        })

      assert html =~ ~s{value="Producción"}
    end

    test "input/1 keeps the value on hidden inputs (form plumbing)" do
      html =
        render_component(&CoreComponents.input/1, %{
          id: "provider_id",
          name: "credential[provider_id]",
          type: "hidden",
          value: "8b0e5c1a-0000-4000-8000-000000000000"
        })

      assert html =~ ~s{value="8b0e5c1a-0000-4000-8000-000000000000"}
    end
  end
end
