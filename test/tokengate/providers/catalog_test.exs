defmodule Tokengate.Providers.CatalogTest do
  @moduledoc """
  Catalog + dispatch + builtin-lock coverage for the provider catalog.
  """
  use Tokengate.DataCase, async: true

  import Ecto.Query

  alias Tokengate.Providers.{Catalog, CatalogSync, Provider}
  alias Tokengate.Proxy.ProviderAdapter

  describe "catalog" do
    test "every builtin entry has unique key and valid fields" do
      entries = Catalog.all()
      assert length(entries) >= 11

      keys = Enum.map(entries, & &1.key)
      assert length(keys) == length(Enum.uniq(keys))

      Enum.each(entries, fn entry ->
        assert String.starts_with?(entry.base_url, "https://")
        assert entry.dialect in Catalog.dialects()
        assert entry.capabilities != []
        Enum.each(entry.capabilities, &(&1 in Catalog.capabilities()))
      end)
    end

    test "get/1 and by_capability/1" do
      assert Catalog.get("openrouter").dialect == "openrouter"
      assert Catalog.get("nope") == nil

      embeddable = Catalog.by_capability("embedding") |> Enum.map(& &1.key)

      assert "openrouter" in embeddable and "fireworks" in embeddable and
               "qwen_cloud" in embeddable

      refute "kimi" in embeddable
    end

    test "match_by_base_url/1 normalizes trailing slash and case" do
      assert Catalog.match_by_base_url("https://openrouter.ai/api/v1/").key == "openrouter"
      assert Catalog.match_by_base_url("https://api.fireworks.ai/inference/v1").key == "fireworks"
      assert Catalog.match_by_base_url("https://unknown.example.com/v1") == nil
      assert Catalog.match_by_base_url(nil) == nil
    end

    test "embedding_override_conflict?/1 flags only real overrides" do
      refute Catalog.embedding_override_conflict?(%{
               base_url: "https://x.com/v1",
               embedding_base_url: nil
             })

      refute Catalog.embedding_override_conflict?(%{
               base_url: "https://x.com/v1",
               embedding_base_url: "https://x.com/v1/embeddings"
             })

      assert Catalog.embedding_override_conflict?(%{
               base_url: "https://x.com/v1",
               embedding_base_url: "https://other.com/embeddings"
             })
    end
  end

  describe "dispatch/1 by dialect" do
    test "resolves openrouter dialect" do
      assert ProviderAdapter.dispatch(%{dialect: "openrouter"}) ==
               Tokengate.Proxy.OpenRouterAdapter

      assert ProviderAdapter.dispatch(%{"dialect" => "openrouter"}) ==
               Tokengate.Proxy.OpenRouterAdapter
    end

    test "resolves openai dialect and defaults" do
      assert ProviderAdapter.dispatch(%{dialect: "openai"}) == Tokengate.Proxy.OpenAIAdapter
      assert ProviderAdapter.dispatch(%{name: "anything"}) == Tokengate.Proxy.OpenAIAdapter
      assert ProviderAdapter.dispatch(nil) == Tokengate.Proxy.OpenAIAdapter
    end
  end

  describe "provider changeset" do
    test "custom provider takes dialect and capabilities" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "my-relay",
          base_url: "https://relay.example.com/v1/",
          dialect: "openai",
          capabilities: ["llm", "embedding"]
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :base_url) == "https://relay.example.com/v1"
    end

    test "builtin identity fields are locked once source is builtin" do
      changeset =
        Provider.changeset(%Provider{source: "builtin", key: "openrouter"}, %{
          name: "hacked",
          base_url: "https://evil.example.com/v1",
          dialect: "openai",
          capabilities: ["llm"],
          status: "disabled"
        })

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :name)
      refute Ecto.Changeset.get_change(changeset, :base_url)
      refute Ecto.Changeset.get_change(changeset, :dialect)
      refute Ecto.Changeset.get_change(changeset, :capabilities)
      assert Ecto.Changeset.get_change(changeset, :status) == "disabled"
    end

    test "invalid dialect and capabilities are rejected" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "x",
          base_url: "https://x.com/v1",
          dialect: "cohere",
          capabilities: ["rerank"]
        })

      refute changeset.valid?
    end
  end

  describe "CatalogSync.sync/0" do
    test "upserts builtins without touching custom rows" do
      {:ok, custom} =
        %Provider{}
        |> Provider.changeset(%{
          name: "my-own",
          base_url: "https://mine.example.com/v1",
          capabilities: ["llm"]
        })
        |> Tokengate.Repo.insert()

      :ok = CatalogSync.sync()

      assert Catalog.get("qwen_cloud").base_url ==
               Tokengate.Repo.get_by!(Provider, key: "qwen_cloud").base_url

      # Idempotent: builtin rows still one per catalog entry, and the
      # custom row is untouched.
      :ok = CatalogSync.sync()

      assert Repo.one(from p in Provider, where: p.source == "builtin", select: count(p.id)) ==
               length(Catalog.all())

      mine = Tokengate.Repo.get_by!(Provider, name: "my-own")
      assert mine.id == custom.id
      assert mine.source == "custom"
      assert mine.dialect == "openai"
    end
  end
end
