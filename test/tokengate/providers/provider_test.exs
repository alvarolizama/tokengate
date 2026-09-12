defmodule Tokengate.Providers.ProviderTest do
  @moduledoc "Unit tests for Provider changeset logic."
  use ExUnit.Case, async: true
  alias Tokengate.Providers.Provider

  describe "changeset/2" do
    test "requires name and base_url" do
      changeset = Provider.changeset(%Provider{}, %{})
      refute changeset.valid?
      assert %{name: [_], base_url: [_]} = errors_on(changeset)
    end

    test "accepts valid custom provider with dialect and capabilities" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "my-relay",
          base_url: "https://relay.example.com/v1",
          dialect: "openrouter",
          capabilities: ["llm", "embedding"]
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :source) == "custom"
      assert Ecto.Changeset.get_field(changeset, :dialect) == "openrouter"
      assert Ecto.Changeset.get_field(changeset, :capabilities) == ["llm", "embedding"]
    end

    test "defaults custom provider to openai dialect and llm capability" do
      changeset =
        Provider.changeset(%Provider{}, %{name: "x", base_url: "https://x.example.com/v1"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :dialect) == "openai"
      assert Ecto.Changeset.get_field(changeset, :source) == "custom"
    end

    test "trims trailing slash from base_url" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "x",
          base_url: "https://x.example.com/v1/"
        })

      assert Ecto.Changeset.get_change(changeset, :base_url) == "https://x.example.com/v1"
    end

    test "rejects invalid status" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.example.com/v1",
          status: "bogus"
        })

      assert %{status: [_]} = errors_on(changeset)
    end

    test "rejects invalid dialect and unknown capabilities" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.example.com/v1",
          dialect: "cohere",
          capabilities: ["rerank"]
        })

      refute changeset.valid?
      assert %{dialect: [_]} = errors_on(changeset)
      assert %{capabilities: [_]} = errors_on(changeset)
    end
  end

  # Helper to extract error messages from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
