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

    test "accepts valid provider attributes" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "openrouter",
          base_url: "https://openrouter.ai/api/v1",
          embedding_base_url: "https://openrouter.ai/api/v1/embeddings",
          rerank_base_url: "https://openrouter.ai/api/v1/rerank"
        })

      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :embedding_base_url) ==
               "https://openrouter.ai/api/v1/embeddings"

      assert Ecto.Changeset.get_field(changeset, :rerank_base_url) ==
               "https://openrouter.ai/api/v1/rerank"
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

    test "normalizes empty-string URL overrides to nil" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.openai.com/v1",
          embedding_base_url: "",
          rerank_base_url: ""
        })

      assert Ecto.Changeset.get_field(changeset, :embedding_base_url) == nil
      assert Ecto.Changeset.get_field(changeset, :rerank_base_url) == nil
    end
  end

  # Helper to extract error messages from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
