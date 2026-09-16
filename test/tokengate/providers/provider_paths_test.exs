defmodule Tokengate.Providers.ProviderPathsTest do
  @moduledoc """
  Unit tests for the path-resolution tiers: the provider's own override, the
  catalog code override, then the generic OpenAI-compatible default.
  """

  use ExUnit.Case, async: true
  alias Tokengate.Providers.ProviderPaths

  describe "resolve/2" do
    test "falls back to the generic OpenAI-compatible default" do
      assert ProviderPaths.resolve(%{key: "mi-relay"}, :chat) == "/chat/completions"
      assert ProviderPaths.resolve(%{key: "mi-relay"}, :models) == "/models"
      assert ProviderPaths.resolve(%{key: "openrouter"}, :embeddings) == "/embeddings"
      assert ProviderPaths.resolve(%{key: "openrouter"}, "rerank") == "/rerank"
      assert ProviderPaths.resolve(%{key: "openrouter"}, :music) == "/music/generations"
    end

    test "the provider's own override wins, by storage key or by code atom" do
      provider = %{key: "mi-relay", path_overrides: %{"chat" => "/v1/chat"}}

      assert ProviderPaths.resolve(provider, :chat) == "/v1/chat"
      assert ProviderPaths.resolve(provider, "chat") == "/v1/chat"
    end

    test "an absolute URL override is kept as-is (service on another host)" do
      provider = %{
        key: "mi-relay",
        path_overrides: %{"rerank" => "https://ranker.example.com/v1/rerank"}
      }

      assert ProviderPaths.resolve(provider, :rerank) == "https://ranker.example.com/v1/rerank"
    end

    test "a blank override inherits instead of pointing at the bare base URL" do
      provider = %{path_overrides: %{"chat" => "", "models" => "   "}}

      assert ProviderPaths.resolve(provider, :chat) == "/chat/completions"
      assert ProviderPaths.resolve(provider, :models) == "/models"
    end

    test "an override for another service never leaks into this one" do
      provider = %{path_overrides: %{"embeddings" => "/embed"}}

      assert ProviderPaths.resolve(provider, :chat) == "/chat/completions"
      assert ProviderPaths.resolve(provider, :embeddings) == "/embed"
    end

    test "reads overrides off the plain map the routing cache hands the adapters" do
      provider = %{"path_overrides" => %{"embeddings" => "/embed"}}

      assert ProviderPaths.resolve(provider, :embeddings) == "/embed"
      assert ProviderPaths.resolve(provider, :chat) == "/chat/completions"
    end

    test "returns nil for a service outside the vocabulary (caller keeps its default)" do
      assert ProviderPaths.resolve(%{}, :moderation) == nil
    end

    test "a provider with no key at all still resolves the generic default" do
      assert ProviderPaths.resolve(nil, :chat) == "/chat/completions"
    end
  end

  describe "normalize/1" do
    test "trims values, drops blanks and trims a trailing slash" do
      assert {:ok, %{"chat" => "/v1/chat", "tts" => "/audio/speech"}} =
               ProviderPaths.normalize(%{
                 "chat" => "  /v1/chat  ",
                 "tts" => "/audio/speech/",
                 "stt" => "",
                 "video" => nil
               })
    end

    test "keeps the root path, which is not a blank" do
      assert {:ok, %{"models" => "/"}} = ProviderPaths.normalize(%{"models" => "/"})
    end

    test "rejects a path that is neither rooted nor absolute" do
      assert {:error, message} = ProviderPaths.normalize(%{"chat" => "chat/completions"})
      assert message =~ "Chat / completions"
    end

    test "rejects an unknown capability instead of storing a dead key" do
      assert {:error, message} = ProviderPaths.normalize(%{"moderation" => "/moderations"})
      assert message =~ "moderation"
    end

    test "rejects a non-string value" do
      assert {:error, _message} = ProviderPaths.normalize(%{"chat" => 42})
    end

    test "an empty set is a valid, no-op override" do
      assert {:ok, %{}} = ProviderPaths.normalize(%{})
      assert {:ok, %{}} = ProviderPaths.normalize(nil)
    end
  end

  describe "describe_all/1" do
    test "covers the whole vocabulary and labels where each path comes from" do
      provider = %{key: "mi-relay", path_overrides: %{"chat" => "/v1/chat"}}
      rows = ProviderPaths.describe_all(provider)

      assert length(rows) == length(ProviderPaths.keys())
      assert Enum.map(rows, & &1.key) == ProviderPaths.keys()

      assert %{source: :provider, effective: "/v1/chat", default: "/chat/completions"} =
               Enum.find(rows, &(&1.key == "chat"))

      assert %{source: :default, effective: "/videos", override: nil, catalog: nil} =
               Enum.find(rows, &(&1.key == "video"))
    end

    test "describe/2 returns nil for a service outside the vocabulary" do
      assert ProviderPaths.describe(%{}, "moderation") == nil
    end
  end
end
