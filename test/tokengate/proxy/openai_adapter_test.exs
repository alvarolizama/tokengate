defmodule Tokengate.Proxy.OpenAIAdapterTest do
  @moduledoc """
  Integration tests for `Tokengate.Proxy.OpenAIAdapter` against a live
  Bandit server: passthrough fidelity, auth header, error classification,
  timeouts and SSE streaming.
  """

  use ExUnit.Case, async: false
  alias Tokengate.Proxy.OpenAIAdapter

  @port 41234

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    # The generic default paths of the six services the proxy routes by path
    # (the `ProviderPaths` vocabulary). The test server answers 200 on any of
    # them — and on the same path behind a `/custom` prefix, which is what the
    # path-override tests point at — so callers assert which path the wire saw.
    @service_paths ~w(/rerank /audio/transcriptions /audio/speech /images/generations /videos /music/generations)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        auth = get_req_header(conn, "authorization")

        send(
          pid,
          {:captured, %{method: conn.method, path: conn.request_path, body: body, auth: auth}}
        )
      end

      route(conn, body)
    end

    defp route(conn, body) do
      cond do
        "slow" in conn.path_info ->
          Process.sleep(200)
          json(conn, 200, %{"ok" => true})

        "limited" in conn.path_info ->
          json(conn, 429, %{"error" => "slow down"})

        "broken" in conn.path_info ->
          json(conn, 500, %{"error" => "boom"})

        "bad" in conn.path_info ->
          json(conn, 400, %{"error" => "bad request"})

        conn.request_path == "/models" ->
          json(conn, 200, %{"data" => []})

        # Only reachable through a provider path override: the generic surface
        # would book /chat/completions.
        conn.request_path == "/custom/chat/completions" ->
          chat(conn, body)

        conn.request_path == "/chat/completions" ->
          chat(conn, body)

        # The six path-routed services: any of their default paths — or the
        # same path behind the `/custom` prefix an operator override in the
        # test uses — answers 200, so the caller can assert which path the
        # wire actually saw.
        service_path?(conn.request_path) ->
          json(conn, 200, %{"object" => "service", "model" => "whatever"})

        true ->
          json(conn, 404, %{"error" => "not found"})
      end
    end

    # The generic defaults from `ProviderPaths`, the table the adapter
    # resolves against — the vocabulary is closed, so the test spells out the
    # same six segments the router exposes.
    defp service_path?(path), do: String.trim_leading(path, "/custom") in @service_paths

    defp chat(conn, body) do
      payload = Jason.decode!(body)

      if payload["stream"] == true do
        stream(conn)
      else
        json(conn, 200, %{
          "id" => "chatcmpl-1",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "hola"}}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
        })
      end
    end

    defp stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} =
        chunk(conn, ~s(data: {"choices":[{"delta":{"content":"ho"}}]}\n\n))

      {:ok, conn} =
        chunk(conn, ~s(data: {"choices":[{"delta":{"content":"la"}}]}\n\n))

      {:ok, conn} =
        chunk(
          conn,
          ~s(data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}\n\n)
        )

      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end

  setup do
    :persistent_term.put({TestPlug, :test_pid}, self())
    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})

    provider = %{base_url: "http://localhost:#{@port}"}
    credential = %{api_key_encrypted: "sk-test-key"}

    {:ok, provider: provider, credential: credential}
  end

  defp provider_to(marker) do
    # The adapter appends /chat/completions (or /models) to base_url, so
    # special routes are triggered by marker segments in the path: the plug
    # matches on conn.path_info containing the marker.
    %{base_url: "http://localhost:#{@port}#{marker}"}
  end

  describe "chat_completion/4" do
    test "returns decoded body and latency on success", %{
      provider: provider,
      credential: credential
    } do
      payload = %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "hola"}]}

      assert {:ok, body, latency, _resp_headers} =
               OpenAIAdapter.chat_completion(provider, credential, payload)

      assert body["usage"]["prompt_tokens"] == 10
      assert is_integer(latency) and latency >= 0
    end

    test "payload passes through byte-for-byte (transparent proxy)", %{
      provider: provider,
      credential: credential
    } do
      payload = %{
        "model" => "gpt-4o",
        "messages" => [
          %{"role" => "system", "content" => "custom system prompt — must NOT be stripped"},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
        ],
        "temperature" => 0.7,
        "stream_options" => %{"include_usage" => true},
        "metadata" => %{"custom_field" => "preserved"}
      }

      assert {:ok, _body, _latency, _resp_headers} =
               OpenAIAdapter.chat_completion(provider, credential, payload)

      assert_receive {:captured, %{body: raw, auth: ["Bearer sk-test-key"]}}
      assert Jason.decode!(raw) == payload
    end

    test "429 classifies as :rate_limited", %{credential: credential} do
      assert {:error, :rate_limited, 429, _} =
               OpenAIAdapter.chat_completion(provider_to("/limited"), credential, %{})
    end

    test "500 classifies as :server_error", %{credential: credential} do
      assert {:error, :server_error, 500, _} =
               OpenAIAdapter.chat_completion(provider_to("/broken"), credential, %{})
    end

    test "400 classifies as :bad_request", %{credential: credential} do
      assert {:error, :bad_request, 400, _} =
               OpenAIAdapter.chat_completion(provider_to("/bad"), credential, %{})
    end

    test "receive timeout classifies as :timeout", %{credential: credential} do
      # /slow sleeps 200ms; the adapter URL helper appends the path, so we
      # exercise timeout via a provider pointing at the slow route directly.
      # Transport errors are normalized to the 4-tuple shape (no status, no
      # upstream error message).
      assert {:error, :timeout, nil, nil} =
               OpenAIAdapter.chat_completion(
                 provider_to("/slow"),
                 credential,
                 %{},
                 receive_timeout: 50
               )
    end

    # The provider's own path override (Capacidades modal) is what the wire
    # sees: base_url + the override, not base_url + the adapter default.
    test "honours the provider's own path override", %{credential: credential} do
      provider = %{
        base_url: "http://localhost:#{@port}",
        path_overrides: %{"chat" => "/custom/chat/completions"}
      }

      assert {:ok, body, _latency, _resp_headers} =
               OpenAIAdapter.chat_completion(provider, credential, %{
                 "model" => "gpt-4o",
                 "messages" => []
               })

      assert body["id"] == "chatcmpl-1"
      assert_receive {:captured, %{path: "/custom/chat/completions", method: "POST"}}
    end

    test "an override of another capability leaves chat on the default path", %{
      provider: provider,
      credential: credential
    } do
      provider = Map.put(provider, :path_overrides, %{"embeddings" => "/embed"})

      assert {:ok, _body, _latency, _resp_headers} =
               OpenAIAdapter.chat_completion(provider, credential, %{
                 "model" => "gpt-4o",
                 "messages" => []
               })

      assert_receive {:captured, %{path: "/chat/completions"}}
    end
  end

  describe "stream_chat_completion/4" do
    test "forwards SSE chunks in order, then :sse_done, then the task exits", %{
      provider: provider,
      credential: credential
    } do
      payload = %{"model" => "gpt-4o", "messages" => [], "stream" => true}

      {:ok, pid} = OpenAIAdapter.stream_chat_completion(provider, credential, payload)
      ref = Process.monitor(pid)

      # Headers arrive before any data chunk — drain them.
      assert_receive {:sse_headers, _headers}

      assert_receive {:sse_chunk, chunk1}
      assert %{"choices" => [%{"delta" => %{"content" => "ho"}}]} = Jason.decode!(chunk1)

      assert_receive {:sse_chunk, chunk2}
      assert %{"choices" => [%{"delta" => %{"content" => "la"}}]} = Jason.decode!(chunk2)

      assert_receive {:sse_chunk, chunk3}
      assert %{"usage" => %{"prompt_tokens" => 10}} = Jason.decode!(chunk3)

      assert_receive {:sse_done}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "sets stream: true when the caller forgot", %{provider: provider, credential: credential} do
      {:ok, _pid} = OpenAIAdapter.stream_chat_completion(provider, credential, %{"model" => "x"})
      assert_receive {:captured, %{body: raw}}
      assert Jason.decode!(raw)["stream"] == true
      # Drain headers that arrive before sse_done.
      assert_receive {:sse_headers, _}
      assert_receive {:sse_done}
    end

    test "non-2xx stream reports classified error", %{credential: credential} do
      {:ok, pid} =
        OpenAIAdapter.stream_chat_completion(provider_to("/limited"), credential, %{
          "stream" => true
        })

      ref = Process.monitor(pid)
      assert_receive {:sse_error, {:rate_limited, 429, "slow down"}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "non-2xx stream keeps the provider's error message", %{credential: credential} do
      {:ok, _pid} =
        OpenAIAdapter.stream_chat_completion(provider_to("/bad"), credential, %{
          "stream" => true
        })

      assert_receive {:sse_error, {:bad_request, 400, message}}
      assert message =~ "bad request"
    end
  end

  describe "service_post/5" do
    # One test per capability: the default path from the `ProviderPaths`
    # table, then the operator's override for the same service — the wire
    # must see `base_url` + each one, never the other.
    test "rerank: /rerank, and the operator's override wins", ctx do
      assert_service_path(:rerank, "/rerank", ctx)
    end

    test "stt: /audio/transcriptions, and the operator's override wins", ctx do
      assert_service_path(:stt, "/audio/transcriptions", ctx)
    end

    test "tts: /audio/speech, and the operator's override wins", ctx do
      assert_service_path(:tts, "/audio/speech", ctx)
    end

    test "image: /images/generations, and the operator's override wins", ctx do
      assert_service_path(:image, "/images/generations", ctx)
    end

    test "video: /videos, and the operator's override wins", ctx do
      assert_service_path(:video, "/videos", ctx)
    end

    test "music: /music/generations, and the operator's override wins", ctx do
      assert_service_path(:music, "/music/generations", ctx)
    end

    test "the body travels untouched and the key is the credential's", %{
      provider: provider,
      credential: credential
    } do
      payload = %{"model" => "rerank-v1", "query" => "hola", "top_n" => 3, "documents" => ["a"]}

      assert {:ok, body, _latency, _headers} =
               OpenAIAdapter.service_post(provider, credential, :rerank, payload)

      assert body["object"] == "service"
      assert_receive {:captured, %{body: raw, auth: ["Bearer sk-test-key"]}}
      assert Jason.decode!(raw) == payload
    end

    test "a service outside the vocabulary books the root path instead of crashing", %{
      provider: provider,
      credential: credential
    } do
      # `service_post/5` is only called with the `ProviderPaths` vocabulary, but
      # an unknown key must not raise: the adapter books base_url + "/" and
      # lets the upstream's answer classify.
      assert {:error, :client_error, 404, _message} =
               OpenAIAdapter.service_post(provider, credential, :nonexistent, %{"model" => "x"})

      assert_receive {:captured, %{path: "/", method: "POST"}}
    end
  end

  # The default path first, then the same service with the provider's own
  # override (Capacidades modal) — which must win over the generic default.
  defp assert_service_path(service, default, %{provider: provider, credential: credential}) do
    assert {:ok, _body, _latency, _headers} =
             OpenAIAdapter.service_post(provider, credential, service, %{"model" => "x"})

    assert_receive {:captured, %{path: ^default, method: "POST"}}

    override = "/custom" <> default
    overridden = Map.put(provider, :path_overrides, %{to_string(service) => override})

    assert {:ok, _body, _latency, _headers} =
             OpenAIAdapter.service_post(overridden, credential, service, %{"model" => "x"})

    assert_receive {:captured, %{path: ^override, method: "POST"}}
  end

  describe "health_check/2" do
    test "ok on 2xx", %{provider: provider, credential: credential} do
      assert :ok = OpenAIAdapter.health_check(provider, credential)
    end

    test "classified error on failure", %{credential: credential} do
      assert {:error, :rate_limited} =
               OpenAIAdapter.health_check(provider_to("/limited"), credential)
    end
  end
end
