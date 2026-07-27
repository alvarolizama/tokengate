defmodule Tokengate.Proxy.ProviderAdapterTest do
  @moduledoc """
  Tests for `Tokengate.Proxy.ProviderAdapter` classification helpers and
  the `dispatch/1` resolver. The full OpenAI adapter integration (HTTP,
  streaming) is in `openai_adapter_test.exs` because it needs a live
  Bandit server.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Proxy.ProviderAdapter

  describe "classify_status/1" do
    test "429 maps to :rate_limited" do
      assert ProviderAdapter.classify_status(429) == :rate_limited
    end

    test "401, 402, 403 map to :auth_error" do
      assert ProviderAdapter.classify_status(401) == :auth_error
      assert ProviderAdapter.classify_status(402) == :auth_error
      assert ProviderAdapter.classify_status(403) == :auth_error
    end

    test "429 and 529 map to :rate_limited" do
      assert ProviderAdapter.classify_status(429) == :rate_limited
      assert ProviderAdapter.classify_status(529) == :rate_limited
    end

    test "other 4xx map to :client_error" do
      assert ProviderAdapter.classify_status(400) == :client_error
      assert ProviderAdapter.classify_status(404) == :client_error
      assert ProviderAdapter.classify_status(422) == :client_error
    end

    test "5xx map to :server_error" do
      assert ProviderAdapter.classify_status(500) == :server_error
      assert ProviderAdapter.classify_status(502) == :server_error
      assert ProviderAdapter.classify_status(503) == :server_error
      assert ProviderAdapter.classify_status(599) == :server_error
    end
  end

  describe "classify_error/1" do
    test "Mint.TransportError with :timeout reason maps to :timeout" do
      error = %Mint.TransportError{reason: :timeout}
      assert ProviderAdapter.classify_error(error) == :timeout
    end

    test "Mint.TransportError with other reason maps to :connection_error" do
      error = %Mint.TransportError{reason: :connection_refused}
      assert ProviderAdapter.classify_error(error) == :connection_error
    end

    test "Finch.TransportError with timeout reason maps to :timeout" do
      error = %Finch.TransportError{reason: :connect_timeout}
      assert ProviderAdapter.classify_error(error) == :timeout
    end

    test "Finch.TransportError with other reason maps to :connection_error" do
      error = %Finch.TransportError{reason: :connection_closed}
      assert ProviderAdapter.classify_error(error) == :connection_error
    end

    test "Finch.Error with :request_timeout reason maps to :timeout" do
      error = %Finch.Error{reason: :request_timeout}
      assert ProviderAdapter.classify_error(error) == :timeout
    end

    test "Finch.Error with other reason maps to :connection_error" do
      error = %Finch.Error{reason: :connection_closed}
      assert ProviderAdapter.classify_error(error) == :connection_error
    end

    test "bare :timeout atom maps to :timeout" do
      assert ProviderAdapter.classify_error(:timeout) == :timeout
    end

    test "bare :connection_refused atom maps to :connection_error" do
      assert ProviderAdapter.classify_error(:connection_refused) == :connection_error
    end

    test "unknown term maps to :connection_error" do
      assert ProviderAdapter.classify_error({:unknown, :error}) == :connection_error
      assert ProviderAdapter.classify_error("some string") == :connection_error
    end
  end

  describe "dispatch/1" do
    test "returns OpenAIAdapter for 'openai' string" do
      assert ProviderAdapter.dispatch("openai") == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for 'openai-compatible' string" do
      assert ProviderAdapter.dispatch("openai-compatible") == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for :openai atom" do
      assert ProviderAdapter.dispatch(:openai) == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for unknown string" do
      assert ProviderAdapter.dispatch("anthropic") == Tokengate.Proxy.OpenAIAdapter
      assert ProviderAdapter.dispatch("some-unknown-provider") == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for provider map with name" do
      provider = %{name: "openai", base_url: "https://api.openai.com"}
      assert ProviderAdapter.dispatch(provider) == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for provider map with adapter field" do
      provider = %{adapter: "openai", base_url: "https://api.openai.com"}
      assert ProviderAdapter.dispatch(provider) == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for nil" do
      assert ProviderAdapter.dispatch(nil) == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns OpenAIAdapter for empty map" do
      assert ProviderAdapter.dispatch(%{}) == Tokengate.Proxy.OpenAIAdapter
    end

    test "returns the module itself when given an already-loaded module atom" do
      assert ProviderAdapter.dispatch(Tokengate.Proxy.OpenAIAdapter) ==
               Tokengate.Proxy.OpenAIAdapter
    end
  end
end
