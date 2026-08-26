defmodule Tokengate.Providers.ProviderTest do
  @moduledoc "Unit tests for Provider changeset logic."
  use ExUnit.Case, async: true

  alias Tokengate.Providers.Provider

  describe "changeset/2 format handling" do
    test "defaults embedding_format to openai and rerank_format to cohere" do
      changeset =
        Provider.changeset(%Provider{}, %{name: "test", base_url: "https://api.openai.com/v1"})

      assert Ecto.Changeset.get_field(changeset, :embedding_format) == "openai"
      assert Ecto.Changeset.get_field(changeset, :rerank_format) == "cohere"
    end

    test "accepts explicit formats" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "dashscope",
          base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          embedding_format: "dashscope",
          rerank_format: "dashscope"
        })

      assert Ecto.Changeset.get_field(changeset, :embedding_format) == "dashscope"
      assert Ecto.Changeset.get_field(changeset, :rerank_format) == "dashscope"
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

    test "rejects invalid rerank_format" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.example.com/v1",
          rerank_format: "invalid"
        })

      assert %{rerank_format: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts runinfra rerank_format" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "runinfra",
          base_url: "https://api.runinfra.ai/v1",
          rerank_format: "runinfra"
        })

      assert Ecto.Changeset.get_field(changeset, :rerank_format) == "runinfra"
    end

    test "rejects invalid embedding_format" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.example.com/v1",
          embedding_format: "invalid"
        })

      assert %{embedding_format: ["is invalid"]} = errors_on(changeset)
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
