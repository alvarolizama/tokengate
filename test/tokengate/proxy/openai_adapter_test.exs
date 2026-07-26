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

        conn.request_path == "/v1/models" ->
          json(conn, 200, %{"data" => []})

        conn.request_path == "/v1/chat/completions" ->
          chat(conn, body)

        true ->
          json(conn, 404, %{"error" => "not found"})
      end
    end

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
    # The adapter appends /v1/chat/completions (or /v1/models) to base_url, so
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

      assert {:ok, body, latency} = OpenAIAdapter.chat_completion(provider, credential, payload)
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

      assert {:ok, _body, _latency} = OpenAIAdapter.chat_completion(provider, credential, payload)
      assert_receive {:captured, %{body: raw, auth: ["Bearer sk-test-key"]}}
      assert Jason.decode!(raw) == payload
    end

    test "429 classifies as :rate_limited", %{credential: credential} do
      assert {:error, :rate_limited, 429} =
               OpenAIAdapter.chat_completion(provider_to("/limited"), credential, %{})
    end

    test "500 classifies as :server_error", %{credential: credential} do
      assert {:error, :server_error, 500} =
               OpenAIAdapter.chat_completion(provider_to("/broken"), credential, %{})
    end

    test "400 classifies as :client_error", %{credential: credential} do
      assert {:error, :client_error, 400} =
               OpenAIAdapter.chat_completion(provider_to("/bad"), credential, %{})
    end

    test "receive timeout classifies as :timeout", %{credential: credential} do
      # /v1/slow sleeps 200ms; the adapter URL helper appends the path, so we
      # exercise timeout via a provider pointing at the slow route directly.
      assert {:error, :timeout, nil} =
               OpenAIAdapter.chat_completion(
                 provider_to("/slow"),
                 credential,
                 %{},
                 receive_timeout: 50
               )
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
      assert_receive {:sse_done}
    end

    test "non-2xx stream reports classified error", %{credential: credential} do
      {:ok, pid} =
        OpenAIAdapter.stream_chat_completion(provider_to("/limited"), credential, %{
          "stream" => true
        })

      ref = Process.monitor(pid)
      assert_receive {:sse_error, {:rate_limited, 429}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
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
