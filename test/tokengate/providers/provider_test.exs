defmodule Tokengate.Providers.ProviderTest do
  @moduledoc "Unit tests for Provider changeset logic."
  use ExUnit.Case, async: true

  alias Tokengate.Providers.Provider

  describe "changeset/2 rerank dialect normalization" do
    test "sets dialect to cohere when rerank_base_url is nil" do
      changeset =
        Provider.changeset(%Provider{}, %{name: "test", base_url: "https://api.openai.com/v1"})

      assert Ecto.Changeset.get_field(changeset, :rerank_dialect) == "cohere"
      assert Ecto.Changeset.get_field(changeset, :rerank_base_url) == nil
    end

    test "sets dialect to cohere when rerank_base_url is empty string" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.openai.com/v1",
          rerank_base_url: ""
        })

      assert Ecto.Changeset.get_field(changeset, :rerank_dialect) == "cohere"
      assert Ecto.Changeset.get_field(changeset, :rerank_base_url) == nil
    end

    test "defaults dialect to dashscope when rerank_base_url is set" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "dashscope",
          base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          rerank_base_url:
            "https://dashscope-intl.aliyuncs.com/api/v1/services/rerank/text-rerank"
        })

      assert Ecto.Changeset.get_field(changeset, :rerank_dialect) == "dashscope"
    end

    test "preserves explicit dialect when both fields are set" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "custom",
          base_url: "https://api.example.com/v1",
          rerank_base_url: "https://api.example.com/custom-rerank",
          rerank_dialect: "cohere"
        })

      assert Ecto.Changeset.get_field(changeset, :rerank_dialect) == "cohere"
    end

    test "rejects invalid dialect values" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "test",
          base_url: "https://api.example.com/v1",
          rerank_dialect: "invalid"
        })

      assert %{rerank_dialect: ["is invalid"]} = errors_on(changeset)
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
