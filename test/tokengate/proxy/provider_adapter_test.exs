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

    test "400 maps to :bad_request (falls back without penalizing the credential)" do
      assert ProviderAdapter.classify_status(400) == :bad_request
    end

    test "other 4xx map to :client_error" do
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

  describe "classify_raise/1" do
    # `Finch.request/3` RAISES (no devuelve `{:error, _}`) cuando el checkout del
    # pool expira por saturación, y para `:pool_not_available`. Ambos escapaban a
    # todas las cláusulas `{:error, error}` y mataban el request con un 500 sin
    # clasificar y SIN fila en `request_logs`.
    test "a Finch error raised (not returned) is classified like a returned one" do
      assert ProviderAdapter.classify_raise(%Finch.Error{reason: :pool_not_available}) ==
               :connection_error

      assert ProviderAdapter.classify_raise(%Finch.Error{reason: :request_timeout}) == :timeout
    end

    test "a pool checkout timeout raised as RuntimeError maps to :connection_error" do
      # Redacción tomada textual de `deps/finch/lib/finch/http1/pool.ex` (rama
      # `{:timeout, {NimblePool, :checkout, _}}`): Finch no da señal
      # estructurada para este caso, el mensaje ES la señal.
      raised = %RuntimeError{
        message:
          "Finch was unable to provide a connection within the timeout due to excess queuing " <>
            "for connections. Consider adjusting the pool size, count, timeout or reducing the " <>
            "rate of requests if it is possible that the downstream service is unable to keep " <>
            "up with the current rate.\n"
      }

      assert ProviderAdapter.classify_raise(raised) == :connection_error
    end

    # El contrato que evita tragarse bugs propios: solo se clasifica lo de Finch.
    # Cualquier otro raise debe seguir explotando (el caller re-lanza).
    test "an unrelated exception is not classified" do
      assert ProviderAdapter.classify_raise(%RuntimeError{message: "boom"}) == nil
      assert ProviderAdapter.classify_raise(%ArgumentError{message: "nope"}) == nil
      assert ProviderAdapter.classify_raise(%Finch.TransportError{reason: :econnrefused}) == nil
      assert ProviderAdapter.classify_raise(:some_atom) == nil
    end
  end
end
