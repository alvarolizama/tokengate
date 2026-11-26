defmodule TokengateWeb.ProxyControllerTest do
  @moduledoc """
  End-to-end proxy API tests: real HTTP through the endpoint into a live
  Bandit "OpenAI" server — auth, limits, budgets, routing, fallback,
  cost tracking and async logging.
  """

  use TokengateWeb.ConnCase, async: false

  use Oban.Testing, repo: Tokengate.Repo

  import Ecto.Query, only: [from: 2]
  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Logs.WriteWorker
  alias Tokengate.Proxy.ResponseCache
  alias Tokengate.Routing.CircuitBreakerManager

  @boundary "tg-upload-boundary"

  # A real multipart/form-data body for the stt surface: a form field plus a
  # file part whose bytes are binary (invalid UTF-8 on purpose — the
  # byte-for-byte assertion must not depend on the body being text).
  defp multipart_body(model, filename \\ "audio.wav") do
    IO.iodata_to_binary([
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="model"\r\n\r\n),
      "#{model}\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="#{filename}"\r\n),
      "content-type: audio/wav\r\n\r\n",
      <<0x52, 0x49, 0xFF, 0x00, 0x46, 0x4D>>,
      "\r\n",
      "--",
      @boundary,
      "--\r\n"
    ])
  end

  # Same canonical upload with an audio file of a KNOWN size: the stt cost of a
  # per_second/per_minute lane is derived from it (160_000 bytes ≈ 10 s at the
  # 128 kbps the extractor documents).
  defp multipart_body_of_size(model, audio_bytes) do
    IO.iodata_to_binary([
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="model"\r\n\r\n),
      "#{model}\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="audio.wav"\r\n),
      "content-type: audio/wav\r\n\r\n",
      audio_bytes,
      "\r\n--",
      @boundary,
      "--\r\n"
    ])
  end

  # `bytes` bytes of WAV-flavoured audio: enough for the parser to report a
  # `%MediaFile{size}` the cost path can turn into seconds.
  defp audio_of_bytes(bytes) do
    "RIFF" <> <<4::32>> <> "WAVE" <> :binary.copy(<<0>>, bytes - 12)
  end

  # The model part of a multipart body travels as the CLIENT wrote it, so the
  # gateway maps it to the lane's upstream id (`AudioMultipart.rewrite_model/3`).
  # The fixture's lanes answer as `gpt-4o-real-<unique>`.
  defp assert_mapped_model(raw, client_model) do
    assert raw =~ ~s(name="model"\r\n\r\ngpt-4o-real-)
    refute raw =~ client_model
  end

  # Same canonical upload plus an explicit `response_format`, the field each STT
  # provider treats differently.
  defp stt_multipart(model, response_format) do
    IO.iodata_to_binary([
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="model"\r\n\r\n),
      "#{model}\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="response_format"\r\n\r\n),
      "#{response_format}\r\n",
      "--",
      @boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="audio.wav"\r\n),
      "content-type: audio/wav\r\n\r\n",
      <<0x52, 0x49, 0xFF, 0x00, 0x46, 0x4D>>,
      "\r\n--",
      @boundary,
      "--\r\n"
    ])
  end

  defmodule ProviderPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      # JSON only: a multipart body has no JSON to decode, so it is captured
      # raw instead. `{:provider_request, payload}` keeps its historical shape
      # for the JSON tests; the raw body rides its own message.
      payload = decode_json(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:provider_raw_body, body, conn.req_headers})
        if payload != nil, do: send(pid, {:provider_request, payload})
        send(pid, {:provider_request_headers, conn.req_headers})
        send(pid, {:provider_request_path, conn.request_path})
      end

      route(conn, body, payload || %{})
    end

    defp decode_json(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> nil
      end
    end

    defp route(conn, body, payload) do
      cond do
        # Simulates a strictly-validating upstream (Fireworks): any of the
        # configured fields present in the body is a hard 400.
        rejected = rejected_fields(payload) ->
          json(conn, 400, %{
            "error" => %{
              "message" => "Extra inputs are not permitted, field: '#{rejected}'",
              "code" => 400
            }
          })

        "down" in conn.path_info ->
          json(conn, 500, %{"error" => %{"message" => "provider exploded"}})

        # Simulates a provider that rejects the request body for its own
        # reasons (400) while the next candidate would accept it.
        "badrequest" in conn.path_info ->
          json(conn, 400, %{
            "error" => %{"message" => "Invalid parameter: unsupported field", "code" => 400}
          })

        # Simulates an upstream answering a 4xx other than 400 (the caller's
        # payload at fault, not a provider-specific rejection).
        "notfound" in conn.path_info ->
          json(conn, 404, %{"error" => %{"message" => "model not found upstream"}})

        # A `403 tier_restricted` from the OpenAI-compatible media cluster
        # (Helmcode/NaN): the MODEL is outside the credential's plan. It must
        # not disable the credential — every other lane keeps working.
        "tierrestricted" in conn.path_info ->
          json(conn, 403, %{
            "error" => %{
              "message" => "your plan does not include this model",
              "type" => "invalid_request_error",
              "code" => "tier_restricted"
            }
          })

        # A `403` about the key itself: this one DOES disable the credential.
        "keyforbidden" in conn.path_info ->
          json(conn, 403, %{"error" => %{"message" => "invalid api key", "code" => nil}})

        # A tts surface that answers with real audio bytes instead of JSON —
        # the binary passthrough the client must receive untouched.
        "costly-binary-speech" in conn.path_info ->
          conn
          |> put_resp_content_type("audio/mpeg")
          |> put_resp_header("x-litellm-response-cost", "0.000420")
          |> send_resp(200, <<0xFF, 0xFB, 0x90, 0x01>>)

        "binary-speech" in conn.path_info ->
          conn
          |> put_resp_content_type("audio/mpeg")
          |> send_resp(200, <<0xFF, 0xFB, 0x90, 0x00>>)

        # Decisiones: el mock responde en el shape que RECIBIÓ — System One
        # (state + questions map) para los proveedores traducidos, OpenAI
        # Decisions (input + questions list) para los verbatim.
        is_map_key(payload, "state") and is_map(payload["questions"]) ->
          json(conn, 200, %{
            "model" => payload["model"],
            "answers" => %{
              "angry" => %{"type" => "noul", "noul" => 0.6328},
              "route" => %{
                "type" => "choice",
                "choice" => "billing",
                "probabilities" => %{"billing" => 0.9, "technical" => 0.1},
                "confidence" => 0.8
              },
              "urgency" => %{
                "type" => "score",
                "score" => 1.2,
                "legend" => %{"0" => "low", "1" => "high"},
                "probabilities" => %{"0" => 0.8, "1" => 0.2},
                "confidence" => 0.6
              }
            },
            "usage" => %{"input_tokens" => 239, "output_tokens" => 0}
          })

        is_map_key(payload, "input") and is_list(payload["questions"]) ->
          json(conn, 200, %{
            "answers" => [
              %{"type" => "predicate", "name" => "angry", "probability" => 0.99},
              %{
                "type" => "choice",
                "name" => "route",
                "choice" => "billing",
                "probabilities" => [%{"value" => "billing", "probability" => 0.9}],
                "confidence" => 0.8
              }
            ],
            "usage" => %{
              "input_tokens" => 120,
              "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
            }
          })

        # Embeddings cuyo split de cache viaja SOLO en header, como Fireworks
        # Serverless: el body trae el `usage` plano y el header el subconjunto
        # cacheado. Sin leer los headers el request se cobraba a tasa de input
        # completa.
        "cached-embeddings" in conn.path_info ->
          payload = Jason.decode!(body)
          count = payload["input"] |> List.wrap() |> length()

          data =
            for idx <- 0..(count - 1) do
              %{"object" => "embedding", "index" => idx, "embedding" => [0.1, 0.2, 0.3]}
            end

          conn
          |> put_resp_header("fireworks-cached-prompt-tokens", "80")
          |> json(200, %{
            "object" => "list",
            "model" => payload["model"],
            "data" => data,
            "usage" => %{"prompt_tokens" => 100, "total_tokens" => 100}
          })

        "embeddings" in conn.path_info ->
          payload = Jason.decode!(body)
          count = payload["input"] |> List.wrap() |> length()

          data =
            for idx <- 0..(count - 1) do
              %{"object" => "embedding", "index" => idx, "embedding" => [0.1, 0.2, 0.3]}
            end

          json(conn, 200, %{
            "object" => "list",
            "model" => payload["model"],
            "data" => data,
            "usage" => %{"prompt_tokens" => 11, "total_tokens" => 11, "cost" => 0.000011}
          })

        # The three non-chat services, each answered with a shape of its own.
        # Each one is matched by its own marker — an operator override that
        # keeps the segment (as in the override test) still lands here.
        "transcriptions" in conn.path_info ->
          json(conn, 200, %{"text" => "hola mundo"})

        "speech" in conn.path_info ->
          json(conn, 200, %{"audio" => "SUQzBAAAAAA"})

        "images" in conn.path_info ->
          json(conn, 200, %{
            "created" => 1,
            "data" => [%{"b64_json" => "aW1n"}],
            "usage" => %{"input_tokens" => 100, "output_tokens" => 200, "total_tokens" => 300}
          })

        # Un upstream que IGNORA `stream_options.include_usage`: manda su
        # contenido y cierra, sin ningún frame de usage. El costo tiene que
        # llegar igual al cliente (lo emite TokenGate antes del [DONE]).
        "nousagestream" in conn.path_info ->
          usage_less_stream(conn, [])

        # Lo mismo, pero con el costo reportado por el upstream SOLO en header
        # (así lo hace LiteLLM en un stream): el frame de cierre tiene que
        # llevar ese costo, no un $0.
        "headercoststream" in conn.path_info ->
          usage_less_stream(conn, [{"x-litellm-response-cost", "0.000420"}])

        # SurplusIntelligence-shape non-streaming: cost in `usage.buyer_cost_micro`
        # and `x-si-buyer-cost-micro` header, with NO `usage.cost`.
        "simicro" in conn.path_info ->
          conn
          |> put_resp_header("x-si-buyer-cost-micro", "17")
          |> json(200, %{
            "id" => "chatcmpl-si-1",
            "object" => "chat.completion",
            "choices" => [
              %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}
            ],
            "usage" => %{
              "prompt_tokens" => 36,
              "completion_tokens" => 0,
              "total_tokens" => 36,
              "buyer_cost_micro" => 17
            }
          })

        # SurplusIntelligence-shape streaming: `x-si-buyer-cost-micro` header +
        # usage chunk carrying `buyer_cost_micro` (no `cost`).
        "simicrostream" in conn.path_info ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("x-si-buyer-cost-micro", "82")
            |> send_chunked(200)

          chunks = [
            ~s({"id":"chatcmpl-si-s","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}),
            ~s({"id":"chatcmpl-si-s","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":33,"completion_tokens":104,"total_tokens":137,"buyer_cost_micro":82,"cost":0.0000389865}})
          ]

          Enum.reduce(chunks, conn, fn chunk, c ->
            {:ok, c} = Plug.Conn.chunk(c, "data: #{chunk}\n\n")
            c
          end)
          |> then(fn c ->
            {:ok, c} = Plug.Conn.chunk(c, "data: [DONE]\n\n")
            c
          end)

        "slowstream" in conn.path_info ->
          Process.sleep(300)
          stream(conn)

        # Un upstream que manda el primer chunk y después se queda mudo con la
        # conexión abierta: sin `after` en `stream_loop` el cliente quedaría
        # colgado para siempre. El gateway debe cortarlo por inactividad.
        "stallstream" in conn.path_info ->
          stall_stream(conn)

        # A chat answer with NO reported cost: forces the manual-pricing
        # fallback path (usage tokens, but no `cost` anywhere).
        "nocost" in conn.path_info ->
          json(conn, 200, %{
            "id" => "chatcmpl-nocost",
            "object" => "chat.completion",
            "choices" => [
              %{"index" => 0, "message" => %{"role" => "assistant", "content" => "qué onda"}}
            ],
            "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30}
          })

        "hang" in conn.path_info ->
          # Simulates a hung/saturated provider: never answers within any
          # reasonable receive_timeout. The caller must configure a short
          # receive_timeout_ms on the credential so the test stays fast. The
          # sleep is longer than any test in this file but bounded, so the
          # handler does not outlive its (private) hang upstream by much.
          Process.sleep(5_000)
          json(conn, 500, %{"error" => %{"message" => "eventually"}})

        # Un upstream que se cae UNA vez (5xx) y después contesta bien. El
        # reintento contra la MISMA key también acabaría en 200, así que un 200
        # servido por OTRA key del pool sólo puede venir de que la cascada
        # excluyó al miembro que falló — y de que lo intentó una sola vez.
        path_prefixed?(conn, "flaky") ->
          if first_hit?(conn.request_path) do
            json(conn, 500, %{"error" => %{"message" => "provider exploded once"}})
          else
            chat_ok(conn)
          end

        # Lo mismo con un 429: el rate limit también excluye al miembro de
        # inmediato, sin reintentar la misma key.
        path_prefixed?(conn, "ratelimited") ->
          if first_hit?(conn.request_path) do
            json(conn, 429, %{"error" => %{"message" => "rate limited once"}})
          else
            chat_ok(conn)
          end

        true ->
          if payload["stream"] == true do
            stream(conn)
          else
            chat_ok(conn)
          end
      end
    end

    # Respuesta estándar de chat: la misma que recibe todo test que no pide
    # nada especial del upstream.
    defp chat_ok(conn) do
      json(conn, 200, %{
        "id" => "chatcmpl-e2e",
        "object" => "chat.completion",
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "qué onda"}}
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 10,
          "total_tokens" => 30,
          "cost" => 0.00015
        }
      })
    end

    # El primer segmento del path empieza con `prefix`. Los tests que necesitan
    # estado propio usan un segmento único (p. ej. "flaky-1234").
    defp path_prefixed?(conn, prefix) do
      case conn.path_info do
        [segment | _] -> String.starts_with?(segment, prefix)
        [] -> false
      end
    end

    # ¿Es la PRIMERA llamada a este path? El plug corre en el proceso de Bandit,
    # no en el del test, así que el contador vive en `:persistent_term`.
    defp first_hit?(path) do
      hits = :persistent_term.get({__MODULE__, :hits, path}, 0)
      :persistent_term.put({__MODULE__, :hits, path}, hits + 1)
      hits == 0
    end

    defp stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      frames = [
        ~s(data: {"choices":[{"delta":{"content":"qué"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":" onda"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22,"cost":0.00007}}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce_while(frames, conn, fn frame, conn ->
        case chunk(conn, frame) do
          {:ok, conn} -> {:cont, conn}
          # Client closed the connection after the terminal frame — nothing
          # more to write, don't raise a MatchError.
          {:error, :closed} -> {:halt, conn}
        end
      end)
    end

    # Manda UN frame y deja la conexión abierta pero muda: el caso que el
    # timeout de inactividad de `stream_loop` tiene que cortar.
    defp stall_stream(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, ~s(data: {"choices":[{"delta":{"content":"qué"}}]}\n\n))
      Process.sleep(30_000)
      conn
    end

    # SSE con contenido y NINGÚN frame de usage — así contesta un upstream que
    # ignora `stream_options.include_usage`. `headers` permite que la ruta
    # reporte su costo sólo en headers, como hacen los proxies LiteLLM.
    defp usage_less_stream(conn, headers) do
      conn =
        Enum.reduce(headers, conn, fn {key, value}, conn ->
          put_resp_header(conn, key, value)
        end)
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      frames = [
        ~s(data: {"choices":[{"delta":{"content":"qué"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":" onda"}}]}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce_while(frames, conn, fn frame, conn ->
        case chunk(conn, frame) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end

    # Strict-upstream simulation (Fireworks): 400s on any field listed in
    # :persistent_term under {ProviderPlug, :reject_body_fields}.
    defp rejected_fields(payload) do
      reject = :persistent_term.get({__MODULE__, :reject_body_fields}, [])

      Enum.find(reject, &Map.has_key?(payload, &1))
    end
  end

  # Adapter de conexión que simula un cliente HTTP que corta el socket a media
  # respuesta: el frame de usage del upstream (el que reporta el costo) ya se
  # capturó y, acto seguido, el chunk siguiente falla con `{:error, :closed}`
  # como un socket cerrado. Es la única forma de ejercitar `{:client_gone, _}`
  # en ConnTest: su `dispatch/5` reinstala `Plug.Adapters.Test.Conn`.
  defmodule ClientGoneAdapter do
    @moduledoc false

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

    defdelegate send_file(state, status, headers, path, offset, length),
      to: Plug.Adapters.Test.Conn

    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn

    def chunk(state, body) do
      if IO.iodata_to_binary(body) =~ ~s("usage") do
        {:error, :closed}
      else
        Plug.Adapters.Test.Conn.chunk(state, body)
      end
    end
  end

  # Bandit/Plug refuse to SEND a 524: it is not an RFC status code, and Plug
  # raises while building the reason phrase. The documented 524 (Helmcode/NaN
  # answer it for oversized audio) is exactly what P13 must see, so this helper
  # speaks HTTP/1.1 on its own socket: accept, drain one request, answer 524,
  # close — and count the connections, so a same-key retry is observable.
  defmodule Edge524Server do
    @moduledoc false

    def start do
      parent = self()
      pid = spawn_link(fn -> listen(parent) end)

      receive do
        {:edge_524_port, ^pid, port} -> {pid, port}
      after
        2_000 -> raise "the 524 server did not start"
      end
    end

    defp listen(parent) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listen)
      send(parent, {:edge_524_port, self(), port})
      loop(listen, parent, 0)
    end

    defp loop(listen, parent, hits) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          drain(socket)
          send(parent, {:edge_524_hit, hits + 1})

          body = ~s({"error":{"message":"request timeout"}})

          :gen_tcp.send(socket, [
            "HTTP/1.1 524 Gateway Timeout\r\n",
            "content-type: application/json\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "connection: close\r\n\r\n",
            body
          ])

          :gen_tcp.close(socket)
          loop(listen, parent, hits + 1)

        {:error, _reason} ->
          :ok
      end
    end

    # The client must finish writing before the answer, or Finch sees a reset:
    # headers first, then exactly the bytes `content-length` announced.
    defp drain(socket, acc \\ "") do
      case :binary.split(acc, "\r\n\r\n") do
        [head, rest] ->
          read_body(socket, byte_size(rest), content_length(head))

        [_partial] ->
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, chunk} -> drain(socket, acc <> chunk)
            _ -> :ok
          end
      end
    end

    defp content_length(head) do
      head
      |> String.split("\r\n")
      |> Enum.find_value(0, fn line ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            if String.downcase(String.trim(key)) == "content-length",
              do: String.to_integer(String.trim(value))

          _ ->
            nil
        end
      end)
    end

    defp read_body(_socket, have, length) when have >= length, do: :ok

    defp read_body(socket, have, length) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> read_body(socket, have + byte_size(chunk), length)
        _ -> :ok
      end
    end
  end

  setup do
    :persistent_term.put({ProviderPlug, :test_pid}, self())
    :persistent_term.put({ProviderPlug, :reject_body_fields}, [])
    port = Tokengate.TestPort.free_port()
    :persistent_term.put({__MODULE__, :port}, port)
    start_supervised!({Bandit, plug: ProviderPlug, scheme: :http, ip: :loopback, port: port})
    :ok
  end

  # The main fake upstream for THIS test. Its port is ephemeral (bound in
  # setup): fixtures and tests that need a provider URL ask here instead of
  # sharing one hardcoded number with every other test in the file.
  defp upstream_url(path \\ "") do
    "http://localhost:#{:persistent_term.get({__MODULE__, :port})}#{path}"
  end

  ## Fixtures ##################################################################

  defp unique, do: System.unique_integer([:positive])

  defp proxy_fixture(opts \\ %{}) do
    u = unique()

    # El gasto del perfil de límites ahora es su límite mensual. Sin `:credit_units` y sin
    # `:unlimited` el perfil de límites NO deja gastar (los miembros quedarían sin camino
    # salvo top-up) — que es exactamente la conducta nueva.
    group_attrs =
      %{
        name: "Group #{u}",
        default_rpm_limit: Map.get(opts, :rpm_limit, 600),
        default_concurrency_limit: Map.get(opts, :concurrency_limit, 10)
      }
      |> then(fn attrs ->
        cond do
          # Default del fixture: ILIMITADO (espejo del tier-3 de antes), para
          # que los tests que no hablan de crédito no tropiecen con el gate.
          Map.get(opts, :credit_units) ->
            Map.put(attrs, :monthly_spend_limit_usd, to_string(opts.credit_units))

          Map.get(opts, :blocked) ->
            attrs

          true ->
            Map.put(attrs, :unlimited_spend, true)
        end
      end)

    {:ok, group} = Accounts.create_group(group_attrs)

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{u}@example.com",
        name: "User #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{
        user_id: user.id,
        group_id: group.id,
        extra_monthly_budget_usd: Map.get(opts, :extra_daily_budget)
      })

    {:ok, _api_key, token} = Accounts.replace_api_key(member)
    member = Repo.preload(member, :api_key)

    provider_url =
      cond do
        url = Map.get(opts, :base_url) ->
          url

        Map.get(opts, :down) ->
          upstream_url("/down")

        segment = Map.get(opts, :provider_path) ->
          upstream_url("/#{segment}")

        true ->
          upstream_url()
      end

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Provider #{u}",
        base_url: provider_url,
        path_overrides: Map.get(opts, :path_overrides, %{})
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-provider-#{u}"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: "gpt-4o-#{u}",
        context_window: 128_000,
        model_type: Map.get(opts, :model_type, "llm")
      })

    {:ok, _grant} = Providers.grant_model_to_group(group.id, model.id)

    {:ok, model_provider} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "gpt-4o-real-#{u}",
        priority: 1
      })

    %{
      group: group,
      user: user,
      member: member,
      token: token,
      provider: provider,
      credential: credential,
      model: model,
      model_provider: model_provider,
      # El límite mensual del perfil de límites (nil = sin límite propio): es lo que el
      # proxy debita y lo que los tests comparan contra el gasto.
      credit_limit_usd: group.monthly_spend_limit_usd
    }
  end

  defp authed_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Despacha por el endpoint real con `ClientGoneAdapter` instalado: ConnTest
  # reinstala su adapter en `dispatch/5`, así que la llamada va directa.
  defp post_with_closing_client(token, path, body) do
    base = Plug.Test.conn(:post, path, Jason.encode!(body))
    {_adapter, payload} = base.adapter

    conn =
      base
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    conn
    |> Map.put(:adapter, {ClientGoneAdapter, payload})
    |> TokengateWeb.Endpoint.call(TokengateWeb.Endpoint.init([]))
  end

  defp chat_body(model) do
    %{"model" => model, "messages" => [%{"role" => "user", "content" => "hola, ¿cómo vas?"}]}
  end

  defp update_alias_type(model, type) do
    model
    |> Ecto.Changeset.change(model_type: type)
    |> Repo.update!()
  end

  ## Auth ######################################################################

  test "401 without token", %{conn: conn} do
    conn = post(conn, ~p"/v1/chat/completions", chat_body("whatever"))
    assert %{"error" => %{"code" => "missing_api_key"}} = json_response(conn, 401)
  end

  test "401 with invalid token", %{conn: conn} do
    conn =
      conn
      |> authed_conn("tg-nope")
      |> post(~p"/v1/chat/completions", chat_body("whatever"))

    assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
  end

  ## Models #####################################################################

  test "GET /v1/models returns only accessible models with context_window", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    other = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"object" => "list", "data" => models} = json_response(conn, 200)
    ids = Enum.map(models, & &1["id"])
    assert model.name in ids
    refute other.model.name in ids

    entry = Enum.find(models, &(&1["id"] == model.name))
    assert entry["context_window"] == 128_000
    assert entry["owned_by"] == "tokengate"
  end

  ## Chat completions ###########################################################

  test "happy path: response carries cost info, headers, credit spend and async log", %{
    conn: conn
  } do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } = proxy_fixture(%{credit_units: 100})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("x-agent-type", "claude-code")
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    body = json_response(conn, 200)

    # Passthrough content intact
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "qué onda"

    # Cost info injected into usage: market = 20*5/1M + 10*15/1M = 0.00025
    # provider = 20*2.5/1M + 10*10/1M = 0.00015
    assert body["usage"]["prompt_tokens"] == 20
    assert body["usage"]["completion_tokens"] == 10
    assert_in_delta body["usage"]["cost_usd"], 0.00015, 0.0000001

    # Cost headers
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000150"]

    # The request debits the member's credit grant by the real paid cost
    # (0.000150 USD = 150 micro-USD = 150 units of crédito at 1:1).
    assert %{consumed_micro: 150} = Budgets.limit_spend({:user, member.user_id})

    # Log job enqueued → drain → request_log row with the single cost dimension
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.agent_type == "claude-code"
    assert log.model_requested == model.name
    assert log.model_responded =~ "gpt-4o-real"
    assert log.status_code == 200
    assert log.prompt_tokens == 20
    assert log.model_provider_id == model_provider.id
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
  end

  # Un SDK serializa como null explícito los knobs que no usa. Omitir el campo
  # es válido aguas arriba; mandarlo en null no lo es (un upstream estricto
  # responde 400 y el cliente lo lee como error del gateway), así que el proxy
  # los quita antes de codificar y el body llega limpio.
  test "client-sent nulls are stripped before the body reaches the upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{credit_units: 100})

    body =
      chat_body(model.name)
      |> Map.merge(%{
        "max_tokens" => nil,
        "temperature" => nil,
        "top_p" => nil,
        "stream" => nil,
        "tools" => nil,
        "stop" => nil
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", body)

    assert json_response(conn, 200)

    assert_receive {:provider_request, upstream_payload}

    for knob <- ~w(max_tokens temperature top_p stream tools stop) do
      refute Map.has_key?(upstream_payload, knob),
             "el knob #{knob} en null llegó al upstream"
    end

    # El contenido del cliente viaja intacto.
    assert upstream_payload["model"] =~ "gpt-4o-real"
    assert upstream_payload["messages"] == body["messages"]
  end

  test "402 when the user's credit is exhausted", %{conn: conn} do
    # A zero-credit group subscription: the member's only grant has no room, so
    # the next request is rejected before being dispatched.
    %{token: token, model: model} = proxy_fixture(%{credit_units: 0})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "budget_exceeded", "type" => "billing_error"}} =
             json_response(conn, 402)
  end

  @tag :capture_log
  test "rejected budget requests do not leak group concurrency slots", %{conn: conn} do
    # Regression: budget gates used to run AFTER acquire_group_limits, and the
    # concurrency slot was only released inside the try/after that never ran
    # when the `with` short-circuited. N rejected requests leaked N slots and
    # the member ended up permanently 429-blocked (no sweeper on the
    # in-flight table).
    %{token: token, model: model, member: member, group: group} =
      proxy_fixture(%{credit_units: 0, concurrency_limit: 3})

    # Member's credit is exhausted → every request 402s.
    for _ <- 1..3 do
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))
    end

    # The leaked slots would pin the in-flight count at the limit...
    assert Limits.current_concurrency(member.api_key.id) == 0

    # ...and block forever: refill the credit (and drop the cached auth so the
    # new grant amount is picked up) — the 4th request must NOT be blocked.
    {:ok, _} = Accounts.update_group(group, %{"monthly_spend_limit_usd" => "100.00"})
    Tokengate.Accounts.ApiKeyCache.invalidate_group(group.id)

    conn
    |> authed_conn(token)
    |> post(~p"/v1/chat/completions", chat_body(model.name))
    |> json_response(200)
  end

  test "402 when estimated cost exceeds the daily budget (nil group budget is unlimited)", %{
    conn: conn
  } do
    # Nil daily budget means unlimited pool — should pass.
    %{token: token, model: model} = proxy_fixture(%{daily_budget: nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "member extra daily budget raises the effective group limit", %{conn: conn} do
    # Both caps allow the upstream-reported cost of $0.00015; the second
    # request also passes since daily spend ($0.00030) < group + member cap.
    %{token: token, model: model} =
      proxy_fixture(%{daily_budget: "0.001", extra_daily_budget: "0.01"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "429 when group concurrency limit is exceeded", %{conn: conn} do
    %{token: token, model: model, member: member} =
      proxy_fixture(%{concurrency_limit: 1})

    # Simulate an in-flight request holding the only slot
    :ok = Limits.acquire(member.api_key.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(member.api_key.id)
  end

  test "429 when RPM exceeded", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{rpm_limit: 1})

    conn1 =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn1, 200)

    conn2 =
      build_conn()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn2, 429)
  end

  test "429 rate-limit responses carry a Retry-After header", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{rpm_limit: 1})

    conn1 =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn1, 200)

    conn2 =
      build_conn()
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn2, 429)
    [retry_after] = get_resp_header(conn2, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  test "cascade exhausted on rate limits reports provider_rate_limited (not concurrency)", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the provider's RPM so every route attempt is rejected with
    # provider_rate_limited — the cascade then exhausts on rate limits.
    [mp] = Providers.list_model_providers(model.id)
    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_rpm: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: 1, concurrency_limit: nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_rate_limited"}} = json_response(conn, 429)

    Limits.release(cred.id)
  end

  test "404 for a model the key cannot access", %{conn: conn} do
    %{token: token} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body("gpt-9000-does-not-exist"))

    assert %{"error" => %{"code" => "model_not_found"}} = json_response(conn, 404)
  end

  test "503 when the only provider is down (breaker records the failure)", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{down: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  test "fallback: first provider 500, second provider answers", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})

    # Second, healthy provider at lower priority (higher number)
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: upstream_url()
      })

    {:ok, cred2} =
      Providers.create_credential(%{provider_id: provider2.id, api_key_encrypted: "sk-healthy"})

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
  end

  test "fallback: the failed attempt log carries the upstream error message", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})

    # Second, healthy provider at lower priority (higher number)
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: upstream_url()
      })

    {:ok, cred2} =
      Providers.create_credential(%{provider_id: provider2.id, api_key_encrypted: "sk-healthy"})

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # The down provider 500s fast, so it gets 1 initial + @max_retries_per_provider (1)
    # retry before being excluded (each one logs a fallback entry), then
    # the healthy provider answers and logs the final success: 2 + 1 jobs.
    assert %{success: 3} = Oban.drain_queue(queue: :logs)

    fallback_logs =
      Repo.all(
        from l in RequestLog,
          where: l.model_id == ^model.id and l.error_reason == "provider_internal_error"
      )

    assert fallback_logs != []

    Enum.each(fallback_logs, fn log ->
      assert log.status_code == 200
      assert log.provider_status_code == 500
      assert log.error_message == "provider exploded"
    end)
  end

  test "el texto del upstream viaja al cliente y a request_logs en un 400 sin fallback", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()
    make_first_provider_reject(model)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    # El mensaje genérico se conserva como PREFIJO (un cliente que matchea esa
    # cadena sigue funcionando) y el detalle del vendor se anexa: sin él, el
    # 400 es indiagnosticable desde el lado del cliente.
    assert %{"error" => %{"code" => "upstream_client_error", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "Provider rejected the request (400)"
    assert message =~ "Invalid parameter: unsupported field"

    Oban.drain_queue(queue: :logs)

    log =
      Repo.one(
        from l in RequestLog,
          where: l.model_id == ^model.id and l.status_code == 400,
          order_by: [desc: l.inserted_at],
          limit: 1
      )

    assert log, "no se escribió la fila 400"
    assert log.error_reason == "bad_request"
    assert log.error_message == "Invalid parameter: unsupported field"
  end

  ## Timeout retry policy ######################################################

  # Adds a second, healthy provider+credential at lower priority so the
  # router has somewhere to fall back to.
  defp add_healthy_fallback(model, u) do
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: upstream_url()
      })

    {:ok, cred2} =
      Providers.create_credential(%{
        provider_id: provider2.id,
        api_key_encrypted: "sk-healthy-#{u}"
      })

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    cred2
  end

  # Starts a PRIVATE hang upstream and points the model's first (priority 1)
  # provider at it with a short receive_timeout. The origin belongs to this
  # test alone on purpose: a timed-out request leaves Finch's keep-alive
  # connection in the pool (still open, its answer arriving later), and a
  # shared origin would let that stale response land on the NEXT attempt's
  # request — the source of the `{:status, ref, _}` CaseClauseError this suite
  # used to hit. A unique port keeps the abandoned connection away from every
  # other attempt.
  defp make_first_provider_hang(model) do
    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    port = start_hang_upstream()

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: "http://localhost:#{port}/hang",
        receive_timeout_ms: 200
      })
  end

  # A second Bandit instance (own port ⇒ own Finch pool) serving the same
  # ProviderPlug: the "hang" branch lives there.
  defp start_hang_upstream do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: :loopback])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: ProviderPlug, scheme: :http, ip: :loopback, port: port},
        id: :hang_upstream
      )
    )

    port
  end

  # Points the model's first (priority 1) provider at an endpoint that always
  # answers 400 — a body that provider refuses for its own reasons, while the
  # fallback candidate serves it. Returns the credential id.
  defp make_first_provider_reject(model) do
    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: upstream_url("/badrequest")
      })

    model_provider.credential_id
  end

  # Drains every {:provider_request, _} message ProviderPlug sent — one per
  # upstream attempt (retries and fallbacks included).
  defp collect_provider_hits do
    for _ <- 1..100 do
      receive do
        {:provider_request, payload} -> payload
      after
        0 -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # Every upstream attempt as {path, payload}: the plug emits, per attempt,
  # raw_body → payload → headers → path, so payloads and paths are matched up
  # in arrival order.
  defp provider_calls do
    messages =
      Stream.repeatedly(fn ->
        receive do
          msg -> msg
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    payloads = for {:provider_request, payload} <- messages, do: payload
    paths = for {:provider_request_path, path} <- messages, do: path

    Enum.zip(payloads, paths)
  end

  # Points a credential's provider at a DIRECT catalog provider — an upstream
  # that documents nothing beyond its own schema. `path_suffix` targets a
  # specific upstream of the test plug.
  defp make_credential_provider_direct(credential, catalog_key, path_suffix \\ nil) do
    provider = Repo.get!(Tokengate.Providers.Provider, credential.provider_id)

    case Repo.get_by(Tokengate.Providers.Provider, key: catalog_key) do
      nil -> :ok
      builtin -> {:ok, _} = Repo.delete(builtin)
    end

    attrs =
      %{key: catalog_key}
      |> then(fn
        attrs when is_binary(path_suffix) ->
          Map.put(attrs, :base_url, upstream_url(path_suffix))

        attrs ->
          attrs
      end)

    {:ok, _} = Providers.update_provider(provider, attrs)
    Tokengate.Routing.Cache.invalidate_all()
    :ok
  end

  test "timeout falls back immediately to the second provider (no same-provider retries)", %{
    conn: conn
  } do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    make_first_provider_hang(model)
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # Deterministic behaviour, no wall-clock: the hanging provider is hit
    # exactly ONCE (one timeout and straight to the fallback — the old policy
    # retried the same provider 3× before excluding it) and the healthy
    # candidate's request is the one that follows it.
    [first, second] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    assert [first.provider_model, second.provider_model] ==
             collect_provider_hits() |> Enum.map(& &1["model"])
  end

  test "timeout with a single provider returns 503 after one attempt", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    make_first_provider_hang(model)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)

    # Old policy: 3 attempts × 200ms against the same provider. New policy:
    # exactly one attempt, then the pool is empty → 503.
    [only] = Providers.list_model_providers(model.id)

    assert [only.provider_model] == collect_provider_hits() |> Enum.map(& &1["model"])
  end

  test "fast 500 errors still retry the same provider before falling back", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # The 500 path keeps per-provider retries: the first provider gets hit
    # more than once (initial attempt + retries) before the router moves on.
    # Each hit sends a {:provider_request, _} message from ProviderPlug.
    hits =
      for _ <- 1..100 do
        receive do
          {:provider_request, payload} -> payload
        after
          0 -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    down_hits = Enum.count(hits, fn payload -> payload["model"] =~ "gpt-4o-real" end)
    assert down_hits >= 2, "expected the down provider to be retried, got #{down_hits} hit(s)"
  end

  ## Cascada intra-pool y tope del 80% #########################################

  # Convierte el lane de una sola key de `proxy_fixture/1` en un lane de pool:
  # crea el pool en el provider del lane, mete su key y `:extra_members` keys
  # nuevas, y deja el lane apuntando al pool (XOR: el lane pierde su
  # `credential_id`). El pool hereda el `base_url` del provider del fixture.
  defp mount_pool(%{provider: provider, model_provider: lane, credential: first}, opts) do
    {:ok, pool} = Providers.create_pool(provider, %{name: "pool-#{unique()}"})
    {:ok, _member} = Providers.add_pool_member(pool, first)

    extra_credentials =
      Enum.map(1..Keyword.get(opts, :extra_members, 0)//1, fn i ->
        {:ok, credential} =
          Providers.create_credential(%{
            provider_id: provider.id,
            api_key_encrypted: "sk-pool-#{i}-#{unique()}"
          })

        {:ok, _member} = Providers.add_pool_member(pool, credential)
        credential
      end)

    {:ok, lane} = Providers.update_model_provider(lane, %{credential_id: nil, pool_id: pool.id})

    %{pool: pool, lane: lane, credentials: [first | extra_credentials]}
  end

  # Las api keys que viajaron en el header Authorization, una por intento
  # upstream y en orden: dice qué credencial sirvió cada intento.
  defp upstream_api_keys do
    collect_upstream_headers()
    |> Enum.map(fn headers ->
      Enum.find_value(headers, fn
        {"authorization", "Bearer " <> key} -> key
        _ -> nil
      end)
    end)
  end

  test "a 5xx in one pool member excludes it at once and another member serves", %{conn: conn} do
    f = proxy_fixture(%{provider_path: "flaky-#{unique()}"})
    %{credentials: members} = mount_pool(f, extra_members: 1)

    conn =
      conn
      |> authed_conn(f.token)
      |> post(~p"/v1/chat/completions", chat_body(f.model.name))

    assert json_response(conn, 200)

    keys = upstream_api_keys()

    # Dos intentos con dos keys DISTINTAS: el miembro que devolvió el 500 quedó
    # excluido y el siguiente intento fue a otro miembro del mismo pool.
    assert length(keys) == 2, "esperaba 2 intentos, hubo #{length(keys)}: #{inspect(keys)}"
    assert length(Enum.uniq(keys)) == 2

    [failed_key, served_key] = keys
    member_keys = Enum.map(members, & &1.api_key_encrypted)

    assert failed_key in member_keys
    assert served_key in member_keys

    # La key fallida se intentó UNA sola vez: el miembro quedó excluido en el
    # acto y el 200 lo sirvió el otro miembro del pool. (El caso en que la
    # política vieja reintentaba la misma key —hasta 4 veces— lo cubre el test
    # del pool de un solo miembro.)
    assert Enum.count(keys, &(&1 == failed_key)) == 1
  end

  test "a failed pool member is never retried: a one-member pool falls to the next lane", %{
    conn: conn
  } do
    u = unique()
    f = proxy_fixture(%{provider_path: "flaky-#{unique()}"})
    %{credentials: [pooled]} = mount_pool(f, extra_members: 0)
    fallback = add_healthy_fallback(f.model, u)

    conn =
      conn
      |> authed_conn(f.token)
      |> post(~p"/v1/chat/completions", chat_body(f.model.name))

    assert json_response(conn, 200)

    # Un pool de un miembro: el tope es 1. El 500 del único miembro lo excluye
    # y agota el grupo, así que el siguiente intento es el lane suelto. Con los
    # reintentos por credencial de un lane de una key, la misma key se habría
    # intentado hasta 4 veces (y el reintento habría devuelto 200 desde ELLA).
    assert upstream_api_keys() == [pooled.api_key_encrypted, fallback.api_key_encrypted]
  end

  test "a 429 in one pool member also excludes it at once", %{conn: conn} do
    f = proxy_fixture(%{provider_path: "ratelimited-#{unique()}"})
    %{credentials: members} = mount_pool(f, extra_members: 1)

    conn =
      conn
      |> authed_conn(f.token)
      |> post(~p"/v1/chat/completions", chat_body(f.model.name))

    assert json_response(conn, 200)

    keys = upstream_api_keys()
    member_keys = Enum.map(members, & &1.api_key_encrypted)

    assert length(keys) == 2, "esperaba 2 intentos, hubo #{length(keys)}: #{inspect(keys)}"
    assert length(Enum.uniq(keys)) == 2
    assert Enum.all?(keys, fn key -> key in member_keys end)
  end

  test "a five-member pool stops at four attempts and hands over to the next lane", %{conn: conn} do
    u = unique()
    f = proxy_fixture(%{provider_path: "down"})
    %{credentials: members} = mount_pool(f, extra_members: 4)
    fallback = add_healthy_fallback(f.model, u)

    conn =
      conn
      |> authed_conn(f.token)
      |> post(~p"/v1/chat/completions", chat_body(f.model.name))

    assert json_response(conn, 200)

    keys = upstream_api_keys()
    member_keys = Enum.map(members, & &1.api_key_encrypted)

    # Exactamente cuatro miembros del pool (el 80% de cinco) y después el lane
    # de una key en prioridad 2: cinco intentos, por debajo de los 9 del
    # request. El quinto miembro NUNCA se intenta.
    assert length(keys) == 5, "esperaba 5 intentos, hubo #{length(keys)}: #{inspect(keys)}"
    assert length(keys) <= 9

    {pool_attempts, [last_key]} = Enum.split(keys, 4)

    assert Enum.all?(pool_attempts, &(&1 in member_keys)),
           "el pool intentó una key ajena: #{inspect(pool_attempts)}"

    assert length(Enum.uniq(pool_attempts)) == 4, "el pool repitió miembro"
    assert last_key == fallback.api_key_encrypted
    refute last_key in member_keys
  end

  ## Idempotency-Key #########################################################

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp idempotency_key_from(headers) do
    Enum.find_value(headers, fn
      {"idempotency-key", value} -> value
      _ -> nil
    end)
  end

  # Drains every {:provider_request_headers, _} message from the mailbox.
  defp collect_upstream_headers do
    for _ <- 1..100 do
      receive do
        {:provider_request_headers, headers} -> List.flatten(headers)
      after
        0 -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  test "every upstream request carries x-session-affinity with the API key hash", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()

    affinity =
      Enum.find_value(headers, fn
        {"x-session-affinity", value} -> value
        _ -> nil
      end)

    # Stable per API key (sha256 of the presented token) — this is the hint
    # providers use to group a session's requests onto their cached prefix.
    assert affinity == Tokengate.Accounts.hash_api_key(token)
  end

  test "every upstream attempt carries the same Idempotency-Key", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()
    key = idempotency_key_from(headers)
    assert is_binary(key), "expected an Idempotency-Key header upstream"
    assert key =~ @uuid_regex
  end

  test "retries and provider fallback reuse the same Idempotency-Key", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture(%{down: true})
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # Down provider gets the initial attempt + retries, then the healthy
    # provider answers — all of them must carry one and the same key.
    keys =
      collect_upstream_headers()
      |> Enum.map(&idempotency_key_from/1)

    assert length(keys) >= 2, "expected multiple upstream attempts, got #{length(keys)}"
    assert Enum.all?(keys, &is_binary/1), "every attempt must carry the key"
    assert Enum.uniq(keys) |> length() == 1, "expected one stable key across attempts"
  end

  ## Per-provider request overrides ###########################################

  # The per-ROW omission knob is what an operator reaches for when an upstream
  # rejects a field it receives — the field name is not hardcoded here, and it
  # can be any key the client put in the body (the gateway attaches none).
  test "omit_body_fields strips a client-supplied field for the strict upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} = Providers.update_model_provider(mp, %{omit_body_fields: ["prompt_cache_key"]})
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["prompt_cache_key"])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "prompt_cache_key" => "client-cache-key",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} -> refute Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  # The reasoning DIALECT normalizer: the client sends reasoning knobs in
  # whatever form its SDK produces (nested `reasoning`, scalar
  # `reasoning_effort`, `thinking` toggle) and the gateway reshapes them into
  # the ONE wire form the serving upstream documents — the client cannot know
  # which provider a request lands on. Mirrors the Hermes provider profiles.
  describe "reasoning dialect normalization" do
    setup %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{})
      {:ok, conn: conn, token: token, model: model}
    end

    test ":scalar flattens every form to reasoning_effort (fireworks)", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "fireworks-ai")

      # Distinct messages per iteration: identical canonical bodies would hit
      # the response cache and never reach the upstream.
      forms = [
        {%{"reasoning" => %{"effort" => "high"}}, "uno"},
        {%{"reasoning_effort" => "high"}, "dos"},
        {%{"thinking" => %{"type" => "enabled"}, "reasoning" => %{"effort" => "high"}}, "tres"}
      ]

      for {body_extra, n} <- forms do
        conn =
          conn
          |> Phoenix.ConnTest.recycle()
          |> authed_conn(token)
          |> post(
            ~p"/v1/chat/completions",
            %{
              "model" => model.name,
              "messages" => [%{"role" => "user", "content" => "hola #{n}"}]
            }
            |> Map.merge(body_extra)
          )

        assert json_response(conn, 200)

        receive do
          {:provider_request, payload} ->
            assert payload["reasoning_effort"] == "high"
            refute Map.has_key?(payload, "reasoning")
            refute Map.has_key?(payload, "thinking")
        after
          0 -> flunk("expected an upstream request")
        end
      end
    end

    test ":scalar disabled flattens to none", %{conn: conn, token: token, model: model} do
      make_provider_keyed(model, "fireworks-ai")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning" => %{"enabled" => false},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "none"
          refute Map.has_key?(payload, "reasoning")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":openrouter_nested converts scalar to the nested object", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "openrouter")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "high",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning"] == %{"effort" => "high"}
          refute Map.has_key?(payload, "reasoning_effort")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":toggle_xor_effort never sends both (moonshotai)", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "moonshotai")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning" => %{"effort" => "high"},
          "thinking" => %{"type" => "enabled"},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          # Effort wins; the toggle is dropped: both at once is a Moonshot 400.
          assert payload["reasoning_effort"] == "high"
          refute Map.has_key?(payload, "thinking")
          refute Map.has_key?(payload, "reasoning")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":toggle_xor_effort with only a toggle keeps the toggle", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "moonshotai")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "thinking" => %{"type" => "enabled"},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["thinking"] == %{"type" => "enabled"}
          refute Map.has_key?(payload, "reasoning_effort")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":toggle_and_effort keeps both (zai)", %{conn: conn, token: token, model: model} do
      make_provider_keyed(model, "zai")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning" => %{"effort" => "high", "enabled" => true},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "high"
          assert payload["thinking"] == %{"type" => "enabled"}
          refute Map.has_key?(payload, "reasoning")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":deepseek_native always emits the toggle", %{conn: conn, token: token, model: model} do
      make_provider_keyed(model, "deepseek")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          # No client knobs at all: the toggle is still emitted explicitly —
          # omitted, DeepSeek defaults thinking on and demands echoes.
          assert payload["thinking"] == %{"type" => "enabled"}
          refute Map.has_key?(payload, "reasoning_effort")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test ":passthrough (alibaba) leaves the body untouched", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "alibaba")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "high",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "high"
      after
        0 -> flunk("expected an upstream request")
      end
    end
  end

  # The OPERATOR effort policy (`models.effort_default` / `effort_override`):
  # per-model configuration applied per attempt in the pre-flight. Precedence:
  # override > (none/minimal → default) > client effort > absence. The log row
  # keeps the client's intent in `effort` and stores what the WINNING attempt
  # sent to the wire in `effort_applied`.
  describe "operator effort policy" do
    setup %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{})
      {:ok, conn: conn, token: token, model: model}
    end

    # The fixture's provider has no catalog key → `:passthrough` (RunInfra's
    # case): the client body travels verbatim and the policy must rewrite the
    # knob the client actually sent.
    test "effort_default rewrites a client none on a passthrough upstream", %{
      conn: conn,
      token: token,
      model: model
    } do
      {:ok, _} = Providers.update_model(model, %{effort_default: "low"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "none",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "low"
      after
        0 -> flunk("expected an upstream request")
      end

      Oban.drain_queue(queue: :logs)

      log =
        Repo.one!(from l in RequestLog, where: l.model_id == ^model.id and l.status_code == 200)

      # Intent vs applied: the row distinguishes what the client asked for
      # from what the gateway sent upstream.
      assert log.effort == "none"
      assert log.effort_applied == "low"
    end

    test "effort_default also substitutes a nested minimal", %{
      conn: conn,
      token: token,
      model: model
    } do
      {:ok, _} = Providers.update_model(model, %{effort_default: "medium"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning" => %{"effort" => "minimal"},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert get_in(payload, ["reasoning", "effort"]) == "medium"
      after
        0 -> flunk("expected an upstream request")
      end
    end

    # The OTHER 400 source: on the scalar dialect a client hard-off is
    # flattened to `reasoning_effort: "none"` by the gateway itself, so an
    # `effort_default` has to replace that value too or the policy would leave
    # the exact 400 it exists to prevent.
    test "effort_default replaces the gateway-fabricated none of a client hard-off", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "fireworks-ai")
      {:ok, _} = Providers.update_model(model, %{effort_default: "low"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "thinking" => false,
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "low"
      after
        0 -> flunk("expected an upstream request")
      end

      Oban.drain_queue(queue: :logs)

      log =
        Repo.one!(from l in RequestLog, where: l.model_id == ^model.id and l.status_code == 200)

      # The client expressed no effort at all; the gateway sent the policy's.
      assert log.effort == nil
      assert log.effort_applied == "low"
    end

    test "without policy, a client none reaches the wire untouched (no-op)", %{
      conn: conn,
      token: token,
      model: model
    } do
      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "none",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "none"
      after
        0 -> flunk("expected an upstream request")
      end

      Oban.drain_queue(queue: :logs)

      log =
        Repo.one!(from l in RequestLog, where: l.model_id == ^model.id and l.status_code == 200)

      assert log.effort == "none"
      assert log.effort_applied == "none"
    end

    test "effort_override wins over a client low on a scalar upstream", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "fireworks-ai")
      {:ok, _} = Providers.update_model(model, %{effort_override: "high"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "low",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "high"
      after
        0 -> flunk("expected an upstream request")
      end

      Oban.drain_queue(queue: :logs)

      log =
        Repo.one!(from l in RequestLog, where: l.model_id == ^model.id and l.status_code == 200)

      assert log.effort == "low"
      assert log.effort_applied == "high"
    end

    test "effort_override applies even when the client sends no effort", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "fireworks-ai")
      {:ok, _} = Providers.update_model(model, %{effort_override: "high"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "high"
          refute Map.has_key?(payload, "thinking")
      after
        0 -> flunk("expected an upstream request")
      end

      Oban.drain_queue(queue: :logs)

      log =
        Repo.one!(from l in RequestLog, where: l.model_id == ^model.id and l.status_code == 200)

      assert log.effort == nil
      assert log.effort_applied == "high"
    end

    test "effort_override lifts a client hard-off (the gateway-fabricated none)", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_provider_keyed(model, "fireworks-ai")
      {:ok, _} = Providers.update_model(model, %{effort_override: "high"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning" => %{"enabled" => false},
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          # The scalar dialect would flatten the hard-off to "none" — the
          # exact 400 the policy exists to prevent. The override wins.
          assert payload["reasoning_effort"] == "high"
      after
        0 -> flunk("expected an upstream request")
      end
    end

    test "effort_override on a passthrough upstream rewrites the client knob but never invents one",
         %{
           conn: conn,
           token: token,
           model: model
         } do
      {:ok, _} = Providers.update_model(model, %{effort_override: "low"})

      # The client sent an effort: it is rewritten in place.
      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "none",
          "messages" => [%{"role" => "user", "content" => "uno"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          assert payload["reasoning_effort"] == "low"
      after
        0 -> flunk("expected an upstream request")
      end

      # The client sent no effort: no dialect to emit one, so nothing is
      # invented — the body stays verbatim.
      conn =
        conn
        |> Phoenix.ConnTest.recycle()
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [%{"role" => "user", "content" => "dos"}]
        })

      assert json_response(conn, 200)

      receive do
        {:provider_request, payload} ->
          refute Map.has_key?(payload, "reasoning_effort")
          refute Map.has_key?(payload, "reasoning")
      after
        0 -> flunk("expected an upstream request")
      end
    end

    # Two routes: the first 400s on the body, the fallback answers. The log
    # row must carry the effort value of the WINNING attempt's wire body.
    test "effort_applied records the winning attempt across a fallback", %{
      conn: conn,
      token: token,
      model: model
    } do
      make_first_provider_reject(model)
      add_healthy_fallback(model, unique())
      {:ok, _} = Providers.update_model(model, %{effort_default: "low"})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "reasoning_effort" => "none",
          "messages" => [%{"role" => "user", "content" => "hola"}]
        })

      assert json_response(conn, 200)

      Oban.drain_queue(queue: :logs)

      # Las filas 200 con `error_reason` son la estela del fallback (cada
      # intento que falló y fue recuperado). La fila final real es la única
      # sin error_reason — y debe traer el effort del wire del intento que
      # ganó, no el de los intentos caídos.
      log =
        Repo.one!(
          from l in RequestLog,
            where: l.model_id == ^model.id and l.status_code == 200 and is_nil(l.error_reason)
        )

      assert log.effort == "none"
      assert log.effort_applied == "low"
    end
  end

  test "a 400 that every candidate rejects is surfaced to the client", %{
    conn: conn
  } do
    %{token: token, model: model, model_provider: model_provider} = proxy_fixture(%{})
    credential_id = model_provider.credential_id
    # A field the gateway does NOT know about and therefore never strips: the
    # operator-configured strict upstream rejects it. The gateway now walks the
    # candidate pool on a 400 (the rejection can be provider-specific), and the
    # 400 policy retries the same key before dropping it, but with a single
    # candidate there is nowhere to go — the upstream 4xx must reach the client
    # untouched, never a 503.
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["totally_unknown_field"])

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "totally_unknown_field" => "x",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    elapsed = System.monotonic_time(:millisecond) - start

    assert %{"error" => %{"code" => "upstream_client_error"}} = json_response(conn, 400)

    # Solo hay una credencial: la política de 400 reemite el body dos veces en
    # ESA misma key, back to back, y recién entonces el cascade se queda sin
    # candidatos y surfacea el 4xx al cliente. Sin pausas: los tres intentos
    # deben costar milisegundos, no los 3s que dormía el proceso del request.
    assert length(collect_provider_hits()) == 3
    assert elapsed < 1_000, "expected immediate 400 retries, took #{elapsed}ms"

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # A 400 means "this body is wrong for ME", not "this credential is sick": the
  # request must reach the next candidate, and the provider that rejected it
  # must pay no price at all — credential stays active, breaker counts nothing.
  test "a 400 falls back to the next provider and leaves the rejecting one untouched" do
    u = unique()
    %{model: model, member: member} = proxy_fixture()
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    # Two rounds are enough to clear the breaker threshold (5): a 400 now costs
    # THREE attempts on the same credential, so if the rejection counted this
    # credential would be at 6 failures and the breaker open — and the second
    # round would not start here anymore. A fresh API key per round keeps the
    # router's sticky routing (keyed by api_key_hash + model) from pinning later
    # rounds to the provider that already answered, so every round starts at the
    # rejecting one.
    for i <- 1..2 do
      {:ok, _api_key, token} = Accounts.replace_api_key(member)

      conn =
        build_conn()
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [%{"role" => "user", "content" => "hola #{i} (#{u})"}]
        })

      assert %{"choices" => [%{"message" => %{"content" => "qué onda"}}]} =
               json_response(conn, 200)
    end

    hits = collect_provider_hits()
    rejects = Enum.count(hits, &(&1["model"] =~ "gpt-4o-real"))
    served = Enum.count(hits, &(&1["model"] =~ "gpt-4o-healthy"))

    # Three attempts on the rejecting credential per round — the original one
    # plus the two same-key retries of the 400 policy (the second after the
    # 3-second pause). Only then does the cascade move on, and the fallback
    # serves every round.
    assert rejects == 6, "expected 6 rejections from the primary provider, got #{rejects}"
    assert served == 2, "expected 2 answers from the fallback, got #{served}"

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # The gateway never injects `session_id` NOR `prompt_cache_key` into any
  # upstream body — not even for a provider whose catalog key is
  # "fireworks-ai", where a body field the vendor does not document is a 400.
  # Cache affinity travels in the session HEADER only. This is the request
  # shape that used to trigger the injection (system + user opener ⇒ a
  # fingerprint session_key is derivable).
  # The fixture's custom provider keeps its local test URL — only the catalog
  # key is stamped onto it (builtin rows are identity-locked and point at the
  # real Fireworks endpoint).
  test "no upstream ever receives a session_id or prompt_cache_key body hint (fireworks-keyed included)",
       %{
         conn: conn
       } do
    %{token: token, model: model} = proxy_fixture(%{})

    make_provider_fireworks(model)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        refute Map.has_key?(payload, "session_id"),
               "the gateway must not attach the OpenRouter-style session_id"

        refute Map.has_key?(payload, "prompt_cache_key"),
               "the gateway must not attach the prompt_cache_key body hint"
    after
      0 -> flunk("expected an upstream request")
    end
  end

  # Points the model's only model_provider at a provider whose catalog key is
  # the given one, keeping the fixture's local test URL. Builtin rows are
  # identity-locked (they point at the real upstream endpoint), so the
  # builtin is dropped and the local provider row gets stamped with the key.
  defp make_provider_keyed(model, catalog_key) do
    [mp] = Providers.list_model_providers(model.id)
    credential = Repo.get!(Tokengate.Providers.Credential, mp.credential_id)
    provider = Repo.get!(Tokengate.Providers.Provider, credential.provider_id)

    case Repo.get_by(Tokengate.Providers.Provider, key: catalog_key) do
      nil -> :ok
      builtin -> {:ok, _} = Repo.delete(builtin)
    end

    {:ok, _} = Providers.update_provider(provider, %{key: catalog_key})
    Tokengate.Routing.Cache.invalidate_all()
  end

  defp make_provider_fireworks(model), do: make_provider_keyed(model, "fireworks-ai")

  # Passthrough, and a deliberate behaviour change: the gateway no longer
  # strips a `session_id` the CLIENT put in its body. It used to, for
  # fireworks only, because the gateway also INJECTED that field and right
  # after stripped its own injection plus the client's. With the injection
  # gone the stripping went with it — the field is the client's, and the
  # gateway is a passthrough for everything it does not own.
  #
  # The client's session_id still does its job: it is input #1 of
  # SessionId.derive/2, so it becomes the conversation key, which is then
  # attached under the one hint the gateway sends.
  test "a client-supplied session_id travels untouched (no longer stripped)", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "session_id" => "client-conv-abc",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        assert payload["session_id"] == "client-conv-abc"
        # El gateway no inyecta ningún hint de caché: affinity solo en HEADER.
        refute Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  # The escape hatch for an upstream that would reject that client field: the
  # per-ROW omission override (the catalog-wide one is gone). Worth pinning
  # because it is the answer to "what if a client sends session_id to a strict
  # provider?".
  test "the per-row omit_body_fields override still rescues a strict upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} = Providers.update_model_provider(mp, %{omit_body_fields: ["session_id"]})
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["session_id"])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "session_id" => "client-conv-abc",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    # A 200 proves the strict upstream did not see session_id (it 400s on it).
    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        refute Map.has_key?(payload, "session_id")
        refute Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  test "extra_body merges operator fields into the upstream payload", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} =
      Providers.update_model_provider(mp, %{extra_body: %{"service_tier" => "priority"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        assert payload["service_tier"] == "priority"
        # Gateway-owned keys are protected from override merges.
        refute Map.has_key?(payload, "extra_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  test "omit_headers removes forwarded hints for the upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _} = Providers.update_model_provider(mp, %{omit_headers: ["x-session-id"]})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("user-agent", "test-agent/1.0")
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    headers = List.flatten(collect_upstream_headers())

    refute Enum.any?(headers, fn {k, _v} -> k == "x-session-id" end)
    # Non-omitted forwarded headers still travel.
    assert Enum.any?(headers, fn {k, v} -> k == "user-agent" and v == "test-agent/1.0" end)
  end

  test "embeddings requests also carry an Idempotency-Key", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{
        "model" => model.name,
        "input" => ["hola mundo"]
      })

    assert json_response(conn, 200)

    [headers] = collect_upstream_headers()
    key = idempotency_key_from(headers)
    assert is_binary(key) and key =~ @uuid_regex
  end

  test "concurrency fallback: saturated credential falls back to second credential", %{conn: conn} do
    u = unique()

    # First credential with max_concurrent: 1
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the first credential's only concurrency slot
    mp1 = hd(Providers.list_model_providers(model.id))
    {:ok, _provider1} = Providers.update_provider(mp1.credential.provider, %{max_concurrent: 1})
    cred1 = mp1.credential

    :ok = Limits.acquire(cred1.id, %{rpm_limit: nil, concurrency_limit: 1})

    # Second credential at lower priority (higher number), on a provider that
    # still has headroom.
    {:ok, provider2} =
      Providers.create_provider(%{
        name: "Healthy #{u}",
        base_url: upstream_url(),
        max_concurrent: 5
      })

    {:ok, cred2} =
      Providers.create_credential(%{
        provider_id: provider2.id,
        api_key_encrypted: "sk-healthy-#{u}"
      })

    {:ok, _ap2} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: cred2.id,
        provider_model: "gpt-4o-healthy-#{u}",
        priority: 2
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    Limits.release(cred1.id)
  end

  test "429 provider_concurrency_exceeded when all credentials are saturated", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the only credential's concurrency slot
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_concurrent: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_concurrency_exceeded"}} = json_response(conn, 429)

    Limits.release(cred.id)
  end

  test "gate error logs carry model_id so per-model stats see them", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{})

    # Saturate the only credential's concurrency slot → gate error
    [mp] = Providers.list_model_providers(model.id)

    {:ok, _provider} = Providers.update_provider(mp.credential.provider, %{max_concurrent: 1})
    cred = mp.credential
    :ok = Limits.acquire(cred.id, %{rpm_limit: nil, concurrency_limit: 1})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "provider_concurrency_exceeded"}} = json_response(conn, 429)

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log =
      Repo.one(
        from l in RequestLog,
          where: l.error_reason == "provider_concurrency_exceeded",
          order_by: [desc: l.inserted_at],
          limit: 1
      )

    assert log.model_id == model.id
    assert log.model_requested == model.name

    Limits.release(cred.id)
  end

  ## Prompt pre-flight (mandatory for LLM models) #############################

  # Reusable noisy payload: has duplicate consecutive tool messages, redundant
  # whitespace runs, and a system message that is NOT at the front — exactly the
  # shape the lazy_cleanup / stable_prefix passes are designed to clean.
  defp noisy_payload(model) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => "first prompt"},
        %{"role" => "system", "content" => "you are a helper"},
        %{"role" => "tool", "content" => "tool output A"},
        %{"role" => "tool", "content" => "tool output A"},
        %{"role" => "tool", "content" => "tool output B"},
        %{"role" => "assistant", "content" => "ack"}
      ]
    }
  end

  test "lazy_cleanup_enabled: true dedupes duplicate tool messages before forwarding", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    # Flip the flag on the model created by the fixture.
    {:ok, model_optimized} =
      Providers.update_model(model, %{lazy_cleanup_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_optimized.name))

    assert json_response(conn, 200)

    # The provider received the cleaned payload: consecutive duplicate tool
    # message ("tool output A" sent twice) collapsed into a single copy.
    assert_receive {:provider_request, provider_payload}
    tool_messages = Enum.filter(provider_payload["messages"], &(&1["role"] == "tool"))

    assert length(tool_messages) == 2
    assert Enum.map(tool_messages, & &1["content"]) == ["tool output A", "tool output B"]
  end

  test "pre-flight transforms apply even with both legacy flags off (mandatory)", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    # The legacy flags are explicitly OFF: they no longer gate anything, the
    # gateway applies both passes to every LLM request.
    {:ok, model_default} =
      Providers.update_model(model, %{
        lazy_cleanup_enabled: false,
        prompt_cache_enabled: false
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_default.name))

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}

    assert Enum.map(provider_payload["messages"], & &1["role"]) == [
             "system",
             "user",
             "tool",
             "tool",
             "assistant"
           ]

    assert Enum.map(provider_payload["messages"], & &1["content"]) == [
             "you are a helper",
             "first prompt",
             "tool output A",
             "tool output B",
             "ack"
           ]
  end

  test "prompt_cache_enabled: true hoists every system message to the front", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    {:ok, model_cached} =
      Providers.update_model(model, %{prompt_cache_enabled: true})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", noisy_payload(model_cached.name))

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}
    forwarded_messages = provider_payload["messages"]

    # The system message is now at the front and any other system messages
    # would also be hoisted (none in this fixture, so the front is exactly one).
    assert hd(forwarded_messages)["role"] == "system"
    assert hd(forwarded_messages)["content"] == "you are a helper"

    # The rest of the messages preserve their original relative order.
    # Both passes are mandatory now, so lazy_cleanup also ran and the
    # duplicated consecutive tool message arrives already collapsed.
    rest = tl(forwarded_messages)
    assert Enum.map(rest, & &1["role"]) == ["user", "tool", "tool", "assistant"]

    assert Enum.map(rest, & &1["content"]) == [
             "first prompt",
             "tool output A",
             "tool output B",
             "ack"
           ]
  end

  ## Prompt optimization (lazy cleanup / prompt cache) ##########################

  test "modelo con prompt_cache_enabled y guard_rails combina guard_rails + reorder", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    {:ok, _} =
      Providers.update_model(model, %{
        "prompt_cache_enabled" => true,
        "guard_rails" => "sé breve"
      })

    messages = [
      %{"role" => "user", "content" => "u1"},
      %{"role" => "system", "content" => "regla"}
    ]

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{"model" => model.name, "messages" => messages})

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}

    # inject_guard_rails inserts a NEW system message at the front (the
    # original system is mid-list, not first), then stable_prefix hoists both
    # system messages to the front preserving order.
    assert provider_payload["messages"] == [
             %{"role" => "system", "content" => "sé breve"},
             %{"role" => "system", "content" => "regla"},
             %{"role" => "user", "content" => "u1"}
           ]
  end

  # Misma familia de bug: `messages: null` explícito con un modelo que tiene
  # guard_rails — `Map.get(payload, "messages", [])` devolvía nil y
  # `[msg | nil]` es una improper list que muere después en Jason.encode!.
  test "un messages en null no rompe el payload cuando el modelo tiene guard_rails", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    {:ok, _} = Providers.update_model(model, %{"guard_rails" => "sé breve"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{"model" => model.name, "messages" => nil})

    assert json_response(conn, 200)

    assert_receive {:provider_request, provider_payload}

    # El guard_rails entra como único mensaje, sin improper list.
    assert provider_payload["messages"] == [%{"role" => "system", "content" => "sé breve"}]
  end

  ## cache_control #############################################################

  # El gateway NO inyecta `cache_control` en ningún upstream. El breakpoint es
  # content-parts estilo Anthropic y los upstreams que tipan `content` como
  # string lo rechazan con un 400 que tumba la request completa (Cerebras:
  # "wrong_api_format"; Fireworks: 400 de su validador estricto). El prefijo
  # system viaja como string plano. Tampoco viaja `prompt_cache_key`: el
  # caché implícito upstream es content-keyed, no se pierde.
  test "no upstream receives a cache_control breakpoint; the system prefix stays a string", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture(%{})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", %{
        "model" => model.name,
        "session_id" => "client-conv-abc",
        "messages" => [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "hola, ¿cómo vas?"}
        ]
      })

    assert json_response(conn, 200)

    receive do
      {:provider_request, payload} ->
        system = Enum.find(payload["messages"], &(&1["role"] == "system"))

        # String plano: nada que un validador estricto pueda rechazar.
        assert is_binary(system["content"])
        refute inspect(payload) =~ "cache_control"
        # Ningún hint de caché en el body: affinity solo en HEADER.
        refute Map.has_key?(payload, "prompt_cache_key")
    after
      0 -> flunk("expected an upstream request")
    end
  end

  ## Streaming #################################################################

  # Un `stream_options` en null explícito es un caso REAL de SDK (y el
  # `Map.get(payload, "stream_options", %{})` de ensure_stream_options no cae al
  # default: la clave existe con valor nil → `Map.put(nil, …)` reventaba).
  test "stream: a null stream_options from the client does not crash the proxy", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    body = Map.merge(chat_body(model.name), %{"stream" => true, "stream_options" => nil})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", body)

    assert conn.state == :chunked
    assert response(conn, 200) =~ "[DONE]"

    # El gateway sigue siendo el dueño del stream_options que necesita para
    # contabilizar usage.
    assert_receive {:provider_request, upstream_payload}
    assert upstream_payload["stream_options"]["include_usage"] == true
  end

  test "stream: SSE passthrough with usage cost injection and async log", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    body = response(conn, 200)
    frames = body |> String.split("\n\n", trim: true)

    # Content frames pass through, then the usage frame, then [DONE]
    assert Enum.at(frames, 0) =~ ~s("content":"qué")
    assert Enum.at(frames, 1) =~ ~s("content":" onda")
    assert List.last(frames) == "data: [DONE]"

    # The usage frame carries the injected cost dimensions
    usage_frame = Enum.find(frames, &(&1 =~ "usage"))
    usage_json = usage_frame |> String.trim_leading("data: ") |> Jason.decode!()
    assert_in_delta usage_json["usage"]["cost_usd"], 0.00007, 0.0000001

    # El frame del upstream ya lleva el costo: no se agrega un cierre propio.
    assert Enum.count(frames, &(&1 =~ "\"usage\"")) == 1

    # stream_options.include_usage was requested from the provider
    assert_receive {:provider_request, provider_payload}
    assert provider_payload["stream_options"]["include_usage"] == true

    # Log written with streaming: true
    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.streaming == true
    assert log.prompt_tokens == 20
    assert log.completion_tokens == 2
    # TTFT recorded for streaming: a small non-negative duration in ms
    assert is_integer(log.ttft_ms)
    assert log.ttft_ms >= 0
  end

  test "stream: first-token timeout falls back and returns 503 with a single provider", %{
    conn: conn
  } do
    previous = Application.get_env(:tokengate, :first_token_timeout_ms)
    Application.put_env(:tokengate, :first_token_timeout_ms, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tokengate, :first_token_timeout_ms, previous),
        else: Application.delete_env(:tokengate, :first_token_timeout_ms)
    end)

    %{token: token, model: model} = proxy_fixture()

    # Repoint the provider at the slow stream endpoint
    [model_provider] = Providers.list_model_providers(model.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: upstream_url("/slowstream")
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert %{"error" => %{"type" => "service_unavailable"}} = json_response(conn, 503)
  end

  # C4: un upstream que manda el primer chunk y después se queda mudo mantiene
  # la conexión (y el proceso del request, el slot de concurrencia y la
  # conexión Finch) tomados para siempre. El timeout de inactividad debe matar
  # el upstream, cerrar el stream con un frame de error + [DONE] y registrar el
  # outcome como timeout en el breaker.
  test "stream: an upstream that stalls mid-stream is cut off by the idle timeout", %{
    conn: conn
  } do
    previous = Application.get_env(:tokengate, :stream_idle_timeout_ms)
    Application.put_env(:tokengate, :stream_idle_timeout_ms, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tokengate, :stream_idle_timeout_ms, previous),
        else: Application.delete_env(:tokengate, :stream_idle_timeout_ms)
    end)

    %{token: token, model: model, member: member} =
      proxy_fixture(%{path_overrides: %{"chat" => "/stallstream"}})

    [model_provider] = Providers.list_model_providers(model.id)
    credential_id = model_provider.credential_id

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert conn.state == :chunked
    body = response(conn, 200)

    # El primer chunk pasó y el silencio posterior cerró el stream: error
    # terminal explícito, no un cliente colgado.
    assert body =~ ~s({"error":{"message":"upstream stream stalled"}})
    assert body =~ "[DONE]"

    # El corte quedó registrado como fallo de timeout contra la credencial.
    assert CircuitBreakerManager.details(credential_id).failures == 1

    # La fila reporta el cierre real (504 timeout de stream), no un 200.
    assert %{success: 1} = Oban.drain_queue(queue: :logs)
    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.status_code == 504
    assert log.error_reason == "stream_timeout"
    assert log.streaming == true
  end

  # C1: un cliente que corta la conexión a media respuesta no puede dejar el
  # request sin costo: el proveedor YA cobró lo emitido. El cierre pasa por
  # `finish_stream` (fila 499 + razón) y el hold del budget se liquida con el
  # costo real, no se libera completo.
  test "stream: a client disconnect mid-stream books the emitted cost under 499", %{conn: _conn} do
    %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 100})

    conn =
      post_with_closing_client(
        token,
        "/v1/chat/completions",
        Map.put(chat_body(model.name), "stream", true)
      )

    # El stream llegó a emitir contenido y el frame de usage del upstream
    # (costo real reportado) antes de que el socket apareciera cerrado.
    assert conn.state == :chunked
    assert conn.resp_body =~ ~s("content":"qué")

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.status_code == 499
    assert log.error_reason == "client_gone"
    assert log.streaming == true
    assert log.prompt_tokens == 20
    assert log.completion_tokens == 2
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000070"))

    # Se cobró lo generado: el hold se liquidó con ese costo.
    assert %{consumed_micro: 70} = Budgets.limit_spend({:user, member.user_id})
  end

  # A non-400 4xx (a marketplace/aggregator "no available sellers" 404) is
  # ROUTE-specific: the credential is excluded and the cascade tries the next
  # key. With a single credential the cascade is exhausted at once, so the
  # client sees the upstream 404 — and, like every 4xx, the credential pays
  # nothing (no breaker count, no deactivation).
  test "stream: an upstream 404 is surfaced and does not count against the breaker", %{
    conn: conn
  } do
    %{token: token, model: model} = proxy_fixture()

    [model_provider] =
      Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    credential_id = model_provider.credential_id

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: upstream_url("/notfound")
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert %{"error" => %{"code" => "upstream_client_error", "message" => message}} =
             json_response(conn, 404)

    assert message =~ "model not found upstream"

    # Terminal: a single attempt — the only credential was excluded, so there
    # is no next key to try.
    assert length(collect_provider_hits()) == 1

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # Un 404 "No available sellers for this model" de un upstream tipo marketplace
  # es un estado de ESA key (ese vendedor no está ahora), no del payload. La
  # credencial se excluye y la siguiente de la lista intenta: el usuario no
  # debe ver el 404 mientras queden keys vivas.
  test "chat: a marketplace 404 falls back to the next credential and succeeds", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    add_healthy_fallback(model, u)

    [first | _] = Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)
    credential_id = first.credential_id

    {:ok, _provider} =
      Providers.update_provider(first.credential.provider, %{
        base_url: upstream_url("/notfound")
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)

    # Dos intentos: la key sin sellers y la siguiente de la lista.
    assert length(collect_provider_hits()) == 2

    # La key que dio 404 sigue activa y sin breaker: el 404 no es su culpa.
    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  # Agotada la lista de keys, el 404 del upstream se entrega — nunca un 503
  # "all providers down": el cliente puede actuar sobre un 4xx real.
  test "chat: a 404 from every candidate is surfaced as the upstream 4xx", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    Providers.list_model_providers(model.id)
    |> Enum.each(fn mp ->
      Providers.update_provider(mp.credential.provider, %{
        base_url: upstream_url("/notfound")
      })
    end)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "upstream_client_error", "message" => message}} =
             json_response(conn, 404)

    assert message =~ "model not found upstream"
    assert length(collect_provider_hits()) == 1
  end

  # Mismo contrato en streaming: nada se envía al cliente hasta el primer
  # chunk, así que el fallback ocurre antes de comprometer el 200.
  test "stream: a marketplace 404 falls back to the next credential and streams", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    add_healthy_fallback(model, u)

    [first | _] = Providers.list_model_providers(model.id) |> Enum.sort_by(& &1.priority)

    {:ok, _provider} =
      Providers.update_provider(first.credential.provider, %{
        base_url: upstream_url("/notfound")
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert conn.state == :chunked
    assert response(conn, 200) =~ "[DONE]"
    assert length(collect_provider_hits()) == 2
  end

  # Regression: a 400 on the STREAMING path used to be treated like a
  # retryable server error — the gateway fell back and logged it as
  # `provider_error_400` with no message, masking the cause. A 400 IS now
  # retried across candidates (the rejection is often provider-specific), but
  # when every candidate refuses the same body the client must see the upstream
  # 4xx — never a 503 "all providers down" — and no candidate pays a price.
  test "stream: a 400 rejected by every candidate is surfaced without punishing them", %{
    conn: conn
  } do
    u = unique()
    %{token: token, model: model, model_provider: model_provider} = proxy_fixture()
    add_healthy_fallback(model, u)
    credential_id = model_provider.credential_id

    # Every upstream rejects a field the gateway does not know about, so no
    # candidate can serve this body.
    :persistent_term.put({ProviderPlug, :reject_body_fields}, ["totally_unknown_field"])

    conn =
      conn
      |> authed_conn(token)
      |> post(
        ~p"/v1/chat/completions",
        Map.put(chat_body(model.name), "stream", true)
        |> Map.put("totally_unknown_field", "x")
      )

    assert %{"error" => %{"code" => "upstream_client_error"}} = json_response(conn, 400)

    # Cada credencial se reintenta dos veces antes de excluirla (1 + 2 de la
    # política de 400 por cada una de las dos credenciales): recién agotados los
    # dos reintentos de la última, el cascade se queda sin candidatos.
    assert length(collect_provider_hits()) == 6

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.status(credential_id) == :closed
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  test "stream: a 400 falls back to the next provider", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    body = response(conn, 200)
    assert body =~ ~s("content":"qué")
    assert body =~ "data: [DONE]"

    # Tres intentos en la credencial que rechaza (1 + los 2 reintentos de la
    # política de 400) + uno servido por el fallback.
    assert length(collect_provider_hits()) == 4

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  test "stream: first-token timeout falls back to the second provider immediately", %{conn: conn} do
    previous = Application.get_env(:tokengate, :first_token_timeout_ms)
    Application.put_env(:tokengate, :first_token_timeout_ms, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tokengate, :first_token_timeout_ms, previous),
        else: Application.delete_env(:tokengate, :first_token_timeout_ms)
    end)

    u = unique()
    %{token: token, model: model} = proxy_fixture()

    # First provider streams too slowly (300ms > 100ms first-token budget)
    [model_provider] = Providers.list_model_providers(model.id)

    {:ok, _provider} =
      Providers.update_provider(model_provider.credential.provider, %{
        base_url: upstream_url("/slowstream")
      })

    add_healthy_fallback(model, u)

    start = System.monotonic_time(:millisecond)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

    elapsed = System.monotonic_time(:millisecond) - start

    assert conn.state == :chunked
    assert response(conn, 200)

    # Old policy: 3 retries × 100ms before falling back (~400ms+). New:
    # one 100ms first-token timeout, then straight to the healthy provider.
    assert elapsed < 400, "expected immediate streaming fallback, took #{elapsed}ms"
  end

  ## Embeddings ################################################################

  test "embeddings happy path: passthrough, cost from usage, log with request_type", %{
    conn: conn
  } do
    %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 100})

    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => ["hola", "wey"]})

    body = json_response(conn, 200)

    # Passthrough: two vectors back, upstream model id
    assert [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}, %{"index" => 1}] = body["data"]
    assert body["model"] =~ "gpt-4o-real"

    # Provider-reported usage drives cost (cost 0.000011)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000011"]

    assert %{consumed_micro: 11} = Budgets.limit_spend({:user, member.user_id})

    assert_enqueued(worker: WriteWorker)
    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "embedding"
    assert log.prompt_tokens == 11
    assert log.completion_tokens == 0
    assert log.status_code == 200
  end

  test "embeddings: a cache split reported only in headers prices cached tokens at the cache rate",
       %{
         conn: conn
       } do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } =
      proxy_fixture(%{credit_units: 100, path_overrides: %{"embeddings" => "/cached-embeddings"}})

    update_alias_type(model, "embedding")

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        input_cost_per_million: "1.00",
        cache_cost_per_million: "0.10",
        output_cost_per_million: "0.00"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => ["hola", "wey"]})

    assert json_response(conn, 200)

    # 80 de los 100 tokens de prompt cotizan a la tasa de cache:
    # (100 - 80) × $1/M + 80 × $0.10/M = 0.000028.
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000028"]
    assert %{consumed_micro: 28} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "embedding"
    assert log.prompt_tokens == 100
    assert log.cache_read_tokens == 80
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000028"))
    assert log.cache_hit == false
  end

  test "embeddings: a 400 falls back to the next provider without punishing it", %{conn: conn} do
    u = unique()
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")
    credential_id = make_first_provider_reject(model)
    add_healthy_fallback(model, u)

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => ["hola"]})

    body = json_response(conn, 200)
    assert [%{"embedding" => [0.1, 0.2, 0.3]}] = body["data"]

    # Tres intentos en la credencial que rechaza (1 + los 2 reintentos de la
    # política de 400) + uno servido por el fallback.
    hits = collect_provider_hits()
    assert Enum.count(hits, &(&1["model"] =~ "gpt-4o-real")) == 3
    assert Enum.count(hits, &(&1["model"] =~ "gpt-4o-healthy")) == 1

    assert Providers.get_credential!(credential_id).status == "active"
    assert CircuitBreakerManager.details(credential_id).failures == 0
  end

  test "embeddings accepts a bare string input", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => "una sola"})

    assert %{"data" => [%{"index" => 0}]} = json_response(conn, 200)
  end

  test "embeddings 400 without input", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name})

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "embeddings 400 model_type_mismatch against an llm model", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/embeddings", %{"model" => model.name, "input" => "x"})

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "chat completions 400 model_type_mismatch against an embedding model", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  # The service endpoints now gate by their OWN type: an llm model is not
  # reachable from a service route (and, symmetrically, a service model is
  # only reachable from its endpoint).
  test "service route 400 model_type_mismatch against an llm model", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/transcriptions", %{"model" => model.name, "input" => "audio"})

    # The body gate runs AFTER routing: an llm model answers the routing error it
    # always did, not a body error.
    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "a stt model is reachable from transcriptions and rejected by chat", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "stt"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "GET /v1/models includes model_type", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()
    update_alias_type(model, "embedding")

    conn =
      conn
      |> authed_conn(token)
      |> get(~p"/v1/models")

    assert %{"data" => models} = json_response(conn, 200)
    entry = Enum.find(models, &(&1["id"] == model.name))
    assert entry["model_type"] == "embedding"
  end

  ## Las tres capacidades ruteadas por path #####################################
  #
  # One test per route: the gateway's public segment must land upstream as
  # base_url + the path `ProviderPaths` resolves for that service, the body
  # travels untouched, and the log row is labelled with the service key the
  # Capacidades modal uses (not with the route's name).

  test "POST /v1/audio/transcriptions lands on base_url + /audio/transcriptions", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture(%{model_type: "stt"})
    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_body(conn)["text"] == "hola mundo"
    assert_receive {:provider_request_path, "/audio/transcriptions"}

    assert_receive {:provider_raw_body, received, _headers}
    assert_mapped_model(received, model.name)

    assert %{success: 1} = Oban.drain_queue(queue: :logs)
    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "stt"
  end

  test "POST /v1/audio/speech lands on base_url + /audio/speech", %{conn: conn} do
    conn =
      assert_service_route(conn, "/v1/audio/speech", "/audio/speech", "tts", %{
        "input" => "hola",
        "voice" => "af_heart"
      })

    assert json_body(conn)["audio"] == "SUQzBAAAAAA"
  end

  test "POST /v1/images/generations lands on base_url + /images/generations", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "image"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert %{"data" => [%{"b64_json" => "aW1n"}]} = json_response(conn, 200)
    assert_receive {:provider_request_path, "/images/generations"}
  end

  # An override saved from the Capacidades modal is the ONLY source of the
  # upstream path: it wins over the generic default of the service.
  test "an operator override on the provider row beats the generic default", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{model_type: "image", path_overrides: %{"image" => "/custom/images"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un perro"})

    assert json_response(conn, 200)
    assert_receive {:provider_request_path, "/custom/images"}
  end

  ## Decisiones ###############################################################
  #
  # La superficie pública es `POST /v1/decisions` (shape OpenAI). Un proveedor
  # que habla ese shape lo recibe verbatim; uno que habla System One (la key
  # del catálogo lo declara) recibe el request traducido y su respuesta
  # traducida de vuelta — un solo traductor para todos los resellers de Jev.

  defp decisions_body(model) do
    %{
      "model" => model,
      "input" => "Customer message: I was charged twice for my order.",
      "questions" => [
        %{"type" => "predicate", "name" => "angry", "instructions" => "Is the customer angry?"},
        %{
          "type" => "choice",
          "name" => "route",
          "instructions" => "Which team?",
          "choices" => [%{"value" => "billing"}, %{"value" => "technical"}]
        },
        %{
          "type" => "score",
          "name" => "urgency",
          "instructions" => "How urgent?",
          "levels" => [%{"label" => "low"}, %{"label" => "high"}]
        }
      ]
    }
  end

  test "POST /v1/decisions pasa verbatim a un proveedor OpenAI-shape", %{conn: conn} do
    %{token: token, model: model, model_provider: model_provider} =
      proxy_fixture(%{model_type: "decision"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/decisions", decisions_body(model.name))

    assert %{
             "answers" => [%{"type" => "predicate", "name" => "angry", "probability" => 0.99} | _]
           } =
             json_response(conn, 200)

    assert_receive {:provider_request_path, "/decisions"}

    assert_receive {:provider_request, upstream}
    assert upstream["model"] == model_provider.provider_model
    assert upstream["input"] =~ "charged twice"
    assert is_list(upstream["questions"])
  end

  test "POST /v1/decisions traduce a System One para un proveedor systemone-shape", %{conn: conn} do
    %{token: token, model: model, provider: provider} = proxy_fixture(%{model_type: "decision"})

    # The sandbox may already have materialized the builtin `typesafe` row
    # (CatalogSync), and `key` is unique, so remove it inside this test
    # transaction before the fixture takes its key.
    Repo.delete_all(from p in Tokengate.Providers.Provider, where: p.key == "typesafe")

    provider
    |> Ecto.Changeset.change(key: "typesafe")
    |> Repo.update!()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/decisions", decisions_body(model.name))

    assert %{"answers" => answers} = json_response(conn, 200)

    # La respuesta System One del mock volvió al shape OpenAI: noul →
    # predicate, y las probabilidades del score restauradas con sus labels.
    assert %{"type" => "predicate", "name" => "angry", "probability" => 0.6328} =
             Enum.find(answers, &(&1["name"] == "angry"))

    score = Enum.find(answers, &(&1["name"] == "urgency"))
    assert score["score"] == 1.2
    assert %{"value" => "low", "probability" => 0.8} in score["probabilities"]
    assert %{"value" => "high", "probability" => 0.2} in score["probabilities"]

    assert_receive {:provider_request_path, "/systemone"}

    assert_receive {:provider_request, upstream}
    assert upstream["state"] =~ "charged twice"
    assert upstream["questions"]["angry"]["type"] == "noul"
    assert upstream["questions"]["route"]["criteria"] == %{"billing" => nil, "technical" => nil}
    assert upstream["questions"]["urgency"]["criteria"] == ["low", "high"]
  end

  test "POST /v1/decisions 400 model_type_mismatch contra un llm", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture()

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/decisions", decisions_body(model.name))

    assert %{"error" => %{"code" => "model_type_mismatch"}} = json_response(conn, 400)
  end

  test "POST /v1/decisions 400 con el mensaje real ante un body malformado, sin tocar upstream",
       %{
         conn: conn
       } do
    %{token: token, model: model} = proxy_fixture(%{model_type: "decision"})

    malformed =
      decisions_body(model.name)
      |> Map.put("questions", [
        %{"type" => "choice", "name" => "route", "choices" => ["billing"]}
      ])

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/decisions", malformed)

    # El 400 del validador es del CALLER: mensaje útil, y ninguna credencial
    # elegida, reintentada ni loggeada como fallback.
    assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "choices"
    refute_received {:provider_request_path, _}
  end

  # The image API reports its tokens as `input_tokens`/`output_tokens`: they
  # must drive the cost exactly like a chat usage object would.
  test "images: the image API's token names drive the cost", %{conn: conn} do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } = proxy_fixture(%{credit_units: 100, model_type: "image"})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        input_cost_per_million: "1.00",
        output_cost_per_million: "2.00"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert json_response(conn, 200)

    # 100 in × $1/M + 200 out × $2/M = 0.0005
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000500"]
    assert %{consumed_micro: 500} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "image"
    assert log.prompt_tokens == 100
    assert log.completion_tokens == 200
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000500"))
  end

  # Y con la unidad en la que el lane REALMENTE cobra: un lane de imágenes no se
  # factura por tokens, sino por imagen. `pricing_unit` + `unit_cost` es lo que
  # lo hace cobrable cuando el upstream no reporta coste (que es el caso normal
  # en imagen, vídeo, tts y stt).
  test "image: un lane cobrado por imagen usa unit_cost, no los tokens", %{conn: conn} do
    %{
      token: token,
      model: model,
      member: member,
      model_provider: model_provider
    } = proxy_fixture(%{credit_units: 100, model_type: "image"})

    # Los precios de token TAMBIÉN están puestos: el resultado demuestra cuál
    # de las dos rutas manda cuando la unidad no es de token.
    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        input_cost_per_million: "1.00",
        output_cost_per_million: "2.00",
        pricing_unit: "per_image",
        unit_cost: "0.0400"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert json_response(conn, 200)

    # 1 imagen en la respuesta × $0.04 = 0.04  (NO los 100/200 tokens)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.040000"]
    assert %{consumed_micro: 40_000} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "image"
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.040000"))
  end

  test "image: un lane cobrado por megapíxel usa el tamaño de la request", %{conn: conn} do
    %{token: token, model: model, model_provider: model_provider} =
      proxy_fixture(%{credit_units: 100, model_type: "image"})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        pricing_unit: "per_megapixel",
        unit_cost: "0.0200"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{
        "model" => model.name,
        "prompt" => "un gato",
        "size" => "1024x1024"
      })

    assert json_response(conn, 200)

    # 1 imagen × 1024×1024 px = 1.048576 MP × $0.02 = 0.02097152 → 0.020972
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.020972"]
  end

  test "tts: un lane cobrado por 1k caracteres usa el texto de entrada", %{conn: conn} do
    %{token: token, model: model, member: member, model_provider: model_provider} =
      proxy_fixture(%{credit_units: 100, model_type: "tts"})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        pricing_unit: "per_1k_characters",
        unit_cost: "0.0150"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola mundo",
        "voice" => "af_heart"
      })

    assert json_response(conn, 200)

    # 10 caracteres × $0.015 / 1000 = 0.00015
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000150"]

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "tts"
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000150"))
  end

  # F15/F26: the parameters the gateway can verify against the wire's own
  # OpenAPI are refused locally, with the gateway's own code and zero provider
  # calls. Nothing is translated: the voice vocabulary of a Kokoro lane is not
  # the OpenAI one, but the pack names are per provider and cannot be verified
  # without a real key (owner verifies in W15), so the gateway enforces only what
  # the schema itself states.
  test "tts: a request without voice is a local 400 (the wire requires it)", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "tts"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{"model" => model.name, "input" => "hola"})

    assert %{"error" => %{"code" => "missing_voice", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "voice"
    refute_receive {:provider_request_path, _path}, 100
  end

  test "tts: a response_format outside the documented enum is a local 400", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "tts"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola",
        "voice" => "af_heart",
        "response_format" => "ogg"
      })

    assert %{"error" => %{"code" => "unsupported_response_format", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "mp3"
    refute_receive {:provider_request_path, _path}, 100
  end

  test "tts: the enum the wire serves reaches the upstream", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "tts"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola",
        "voice" => "ef_dora",
        "response_format" => "opus"
      })

    assert json_response(conn, 200)["audio"] == "SUQzBAAAAAA"
    assert_receive {:provider_request, sent}
    assert sent["voice"] == "ef_dora"
    assert sent["response_format"] == "opus"
  end

  test "image: a size the wire cannot parse is a local 400", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "image"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{
        "model" => model.name,
        "prompt" => "un gato",
        "size" => "enorme"
      })

    assert %{"error" => %{"code" => "invalid_image_parameter", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "size"
    refute_receive {:provider_request_path, _path}, 100
  end

  test "image: n must be a positive integer", %{} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "image"})

    for n <- [0, -1, "dos"] do
      conn =
        build_conn()
        |> authed_conn(token)
        |> post(~p"/v1/images/generations", %{
          "model" => model.name,
          "prompt" => "un gato",
          "n" => n
        })

      assert %{"error" => %{"code" => "invalid_image_parameter"}} = json_response(conn, 400)
    end

    refute_receive {:provider_request_path, _path}, 100
  end

  # The gate must not over-reject: `auto` and a real size are what the docs
  # serve, and they still reach the upstream (the per-model RANGES are the
  # catalog's business, not the gateway's).
  test "image: auto and WxH sizes still reach the upstream", %{} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "image"})

    for size <- ["auto", "1024x1024"] do
      conn =
        build_conn()
        |> authed_conn(token)
        |> post(~p"/v1/images/generations", %{
          "model" => model.name,
          "prompt" => "un gato",
          "size" => size,
          "n" => 2
        })

      assert %{"data" => [%{"b64_json" => "aW1n"}]} = json_response(conn, 200)
      assert_receive {:provider_request, sent}
      assert sent["size"] == size
    end
  end

  # Un lane de media SIN precio unitario sigue siendo el $0 honesto: no se
  # inventa un precio por el hecho de tener unidad.
  test "image: sin unit_cost el coste es $0 (no se inventa)", %{conn: conn} do
    %{token: token, model: model, model_provider: model_provider} =
      proxy_fixture(%{credit_units: 100, model_type: "image"})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{pricing_unit: "per_image"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/images/generations", %{"model" => model.name, "prompt" => "un gato"})

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0"]
  end

  # A service whose upstream reports no usage at all (stt answers with the
  # transcript only): the request's own text is estimated, so manual pricing
  # still books something — and with no manual pricing the cost is the honest $0.
  test "stt: no upstream usage falls back to the estimate over the request", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture(%{model_type: "stt"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/transcriptions", %{
        "model" => model.name,
        "input" => "un audio largo",
        "file" => Base.encode64(<<"OggS", 0, 2, 0, 0>>)
      })

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0"]

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "stt"
    assert log.prompt_tokens > 0
    assert log.completion_tokens == 0
  end

  # P12 (F13): the canonical multipart upload carries the DEFAULT
  # `response_format` (`json`), whose answer has no `duration` — only
  # `verbose_json` reports it. The billable quantity of a per_second/per_minute
  # lane therefore has to come from the audio the parser measured: the
  # `%MediaFile{size}`. Before, the extractor only understood base64 request
  # bodies, so every multipart transcription billed $0 in silence.
  test "stt: a multipart json upload bills per_second from the file size", %{conn: conn} do
    %{token: token, model: model, member: member, model_provider: lane} =
      proxy_fixture(%{credit_units: 100, model_type: "stt"})

    {:ok, _lane} =
      Providers.update_model_provider(lane, %{pricing_unit: "per_second", unit_cost: "0.0060"})

    # 160_000 bytes at the documented 128 kbps = 10 s → 10 × $0.006 = $0.06.
    body = multipart_body_of_size(model.name, audio_of_bytes(160_000))

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.060000"]
    assert %{consumed_micro: 60_000} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "stt"
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.060000"))
  end

  test "stt: a multipart json upload bills per_minute from the file size", %{conn: conn} do
    %{token: token, model: model, member: member, model_provider: lane} =
      proxy_fixture(%{credit_units: 100, model_type: "stt"})

    {:ok, _lane} =
      Providers.update_model_provider(lane, %{pricing_unit: "per_minute", unit_cost: "0.1200"})

    body = multipart_body_of_size(model.name, audio_of_bytes(160_000))

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"

    # 10 s = 1/6 min × $0.12 = $0.02.
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.020000"]
    assert %{consumed_micro: 20_000} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.020000"))
  end

  # P13 (F14): a `403 tier_restricted` means the MODEL is outside the
  # credential's plan (whisper-1 was the owner-verified case) — not that the key
  # is dead. The gateway used to classify every 401/402/403 as `:auth_error` and
  # disable the whole credential, taking every other lane of that provider down
  # until a manual reactivation. Now the refusal is scoped: the lane is skipped
  # for this request, the credential stays enabled, and the client gets the
  # upstream's own 403 with a reason it can act on.
  test "a 403 tier_restricted for one model does not disable the credential", %{conn: conn} do
    %{token: token, model: model, member: member, credential: credential} =
      proxy_fixture(%{model_type: "stt", provider_path: "tierrestricted"})

    Phoenix.PubSub.subscribe(Tokengate.PubSub, "alerts")
    credential_id = credential.id

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", stt_multipart(model.name, "json"))

    # The scoped reason reaches the client (not "auth_error", which is what the
    # credential-disabling path answers).
    assert %{"error" => %{"code" => "model_not_available"}} = json_response(conn, 403)

    # The disable path is the ONLY place that broadcasts `:credential_error`, and
    # it is only reached from the `:auth_error` clause: its absence is the
    # proof that this refusal never ran it. (The DB write of that Task is not
    # observable here — it runs outside the sandbox ownership — so the broadcast
    # is the assertion that matters.)
    refute_receive {:credential_error, ^credential_id, _reason}, 150
    assert Providers.get_credential!(credential.id).status == "active"

    # A scoped refusal is deterministic: one attempt, no same-key retry.
    assert_receive {:provider_request_path, "/tierrestricted/audio/transcriptions"}, 1_000
    refute_receive {:provider_request_path, _path}, 200

    assert %{failure: 0, success: drained} = Oban.drain_queue(queue: :logs)
    assert drained >= 1

    log =
      Repo.one(
        from l in RequestLog,
          where: l.group_member_id == ^member.id and l.error_reason == "model_not_available"
      )

    assert log.status_code == 403
  end

  # The other side of F14: a 403 that says nothing about a plan or a model is
  # still the credential's own failure and must keep disabling it.
  #
  # This only became assertable with the `error_at` fix in
  # `disable_credential_async/3`: `DateTime.utc_now/0` carries microseconds and
  # the `:utc_datetime` column rejects them, so the Task used to die before the
  # update AND before the broadcast — the disable was a silent no-op.
  test "a 403 about the key itself still disables the credential", %{conn: conn} do
    %{token: token, model: model, credential: credential} =
      proxy_fixture(%{model_type: "stt", provider_path: "keyforbidden"})

    Phoenix.PubSub.subscribe(Tokengate.PubSub, "alerts")
    credential_id = credential.id

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", stt_multipart(model.name, "json"))

    # No candidate left once the credential is disabled.
    assert conn.status == 503

    assert_receive {:credential_error, ^credential_id, "auth_error_403"}, 1_000
    assert Providers.get_credential!(credential_id).status == "error"
  end

  # P13 (F25): a 524 is the upstream's own edge timing out. The credential is
  # healthy and the same key would just wait out another gateway timeout, so the
  # gateway excludes it for this request instead of retrying it — and the 5xx
  # bucket no longer counts it against the breaker.
  test "a 524 is not retried with the same key", %{conn: conn} do
    {_server, port} = Edge524Server.start()

    %{token: token, model: model} =
      proxy_fixture(%{base_url: "http://127.0.0.1:#{port}"})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    # One attempt: the first upstream call, and no same-key retry behind it.
    assert_receive {:edge_524_hit, 1}, 1_000
    refute_receive {:edge_524_hit, 2}, 250

    # Exhausted cascade for a healthy-but-timed-out lane: the client gets a 503,
    # not the 200 the old "retry three times" never produced either.
    assert conn.status == 503
  end

  # Regresión del lane de CHAT cobrado por llamada: el formulario ofrece
  # `per_request` para lanes llm (Pricing.units_for_type/1), pero el camino de
  # chat pasaba `quantities: %{}` — la cantidad de "per_request" (la llamada
  # misma, 1) nunca llegaba al calculator y el lane facturaba $0 siempre.
  # El stub responde SIN coste reportado para forzar el pricing manual.
  test "chat: un lane cobrado por llamada (per_request) factura unit_cost", %{conn: conn} do
    %{token: token, model: model, member: member, model_provider: model_provider} =
      proxy_fixture(%{credit_units: 100, provider_path: "nocost"})

    {:ok, _} =
      Providers.update_model_provider(model_provider, %{
        pricing_unit: "per_request",
        unit_cost: "0.2500"
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/chat/completions", chat_body(model.name))

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.250000"]
    assert %{consumed_micro: 250_000} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.250000"))
  end

  ## Media passthrough (multipart in, binary out) ##############################
  #
  # The canonical stt call is `multipart/form-data`, and a tts upstream may
  # answer with audio bytes. Both are transport, not routing: the bytes must
  # cross the gateway untouched. See `TokengateWeb.Plugs.MediaBodyParser`.

  test "multipart /v1/audio/transcriptions reaches the upstream with the client's audio and the lane's model",
       %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture(%{model_type: "stt"})
    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"

    # The audio and the other parts travel as sent; the `model` VALUE is mapped to
    # the lane's upstream id, exactly like every JSON surface gets from
    # `execute_simple` — so the body is re-encoded under a gateway boundary.
    assert_receive {:provider_raw_body, received, headers}

    assert {"content-type", "multipart/form-data; boundary=tokengate-" <> _} =
             List.keyfind(headers, "content-type", 0)

    assert_mapped_model(received, model.name)
    assert :binary.match(received, <<0x52, 0x49, 0xFF, 0x00, 0x46, 0x4D>>) != :nomatch

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "stt"
    assert log.status_code == 200
  end

  # The common case: the lane serves the model under the same id the client sent.
  # There is nothing to map, so the bytes and the client's boundary travel
  # untouched.
  test "a multipart whose model already matches the lane crosses byte-for-byte", %{conn: conn} do
    %{token: token, model: model, model_provider: lane} = proxy_fixture(%{model_type: "stt"})
    {:ok, _lane} = Providers.update_model_provider(lane, %{provider_model: model.name})
    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"
    assert_receive {:provider_raw_body, ^body, headers}
    assert {"content-type", "multipart/form-data; boundary=#{@boundary}"} in headers
  end

  test "two different multipart uploads are not one cache entry", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "stt"})

    # Same model, same form field names, different FILE BYTES: the response
    # cache hashes the parsed payload (which cannot carry the file), so a
    # cached hit here would answer the second upload with the first's result.
    first = multipart_body(model.name, "uno.wav")
    second = multipart_body(model.name, "dos.wav")

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", first)

    assert json_response(conn, 200)
    assert_receive {:provider_raw_body, received_first, _headers}
    assert received_first =~ "uno.wav"

    conn =
      conn
      |> recycle()
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", second)

    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-tokengate-cache") == []
    assert_receive {:provider_raw_body, received_second, _headers}
    assert received_second =~ "dos.wav"
    refute received_first == received_second
  end

  # A client that sends the audio as JSON + base64 (or as a text field) used to
  # reach the upstream as `application/json` and come back 422 `body.file` — a
  # schema error that names nothing. The gateway rebuilds a canonical multipart
  # before the call (see `Tokengate.Proxy.AudioMultipart`).
  test "a JSON body with base64 audio reaches the upstream as multipart", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "stt"})
    audio = <<"OggS", 0, 2, 0, 0, 0, 0, 0, 0>>

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/v1/audio/transcriptions",
        Jason.encode!(%{
          "model" => model.name,
          "language" => "es",
          "file" => Base.encode64(audio)
        })
      )

    assert json_response(conn, 200)["text"] == "hola mundo"
    assert_receive {:provider_raw_body, raw, headers}

    assert {"content-type", "multipart/form-data; boundary=" <> _} =
             List.keyfind(headers, "content-type", 0)

    assert raw =~ ~s(name="file"; filename="audio.ogg")
    assert raw =~ ~s(name="language")
    assert :binary.match(raw, audio) != :nomatch
  end

  test "a multipart file part without a filename is rebuilt with one", %{conn: conn} do
    %{token: token, model: model} = proxy_fixture(%{model_type: "stt"})
    audio = <<"OggS", 0, 2, 0, 0>>

    body =
      IO.iodata_to_binary([
        "--",
        @boundary,
        "\r\n",
        ~s(content-disposition: form-data; name="model"\r\n\r\n),
        "#{model.name}\r\n",
        "--",
        @boundary,
        "\r\n",
        ~s(content-disposition: form-data; name="file"\r\n),
        "content-type: audio/ogg\r\n\r\n",
        audio,
        "\r\n",
        "--",
        @boundary,
        "--\r\n"
      ])

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)["text"] == "hola mundo"
    assert_receive {:provider_raw_body, raw, _headers}
    assert raw =~ ~s(name="file"; filename="audio.ogg")
    assert :binary.match(raw, audio) != :nomatch
  end

  test "a transcription body with no audio is a local 400, never an upstream call", %{conn: conn} do
    %{token: token, model: model, member: member} = proxy_fixture(%{model_type: "stt"})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/audio/transcriptions", Jason.encode!(%{"model" => model.name}))

    assert %{"error" => %{"code" => "missing_audio"}} = json_response(conn, 400)
    refute_receive {:provider_raw_body, _raw, _headers}, 100

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.status_code == 400
    assert log.error_reason == "missing_audio"
  end

  # The gate is dialect-aware: DashScope takes the audio as a JSON field
  # (`audio_url`), so a body with no bytes is NOT a multipart problem — the
  # adapter below it owns the translation.
  test "a dashscope transcription with audio_url is not judged by the multipart gate", %{
    conn: conn
  } do
    %{token: token, model: model, provider: provider} = proxy_fixture(%{model_type: "stt"})
    {:ok, _provider} = Providers.update_provider(provider, %{dialect: "dashscope"})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/v1/audio/transcriptions",
        Jason.encode!(%{"model" => model.name, "audio_url" => "https://example.test/a.mp3"})
      )

    assert conn.status == 200
    assert_receive {:provider_request_path, "/chat/completions"}
  end

  # P11 (F12): `response_format` on the transcription surface is a CLOSED enum of
  # `json`/`verbose_json` for every multipart dialect — OpenRouter documents it,
  # and so does the openai-dialect media cluster the catalog ships (Helmcode/NaN,
  # `enum: [json, verbose_json]` in both OpenAPIs, verified 2026-11-17). The
  # gateway used to translate `text` for OpenRouter and forward the rest, so the
  # SAME body answered 200 on one provider and 400 on another. Now every
  # unsupported value is refused locally, with the gateway's own code and zero
  # provider calls — same body, same answer, whichever lane the router picks.
  test "response_format outside json/verbose_json is a local 400 on every multipart dialect" do
    for dialect <- ["openai", "openrouter"],
        format <- ["text", "srt", "vtt"] do
      %{token: token, model: model, provider: provider} = proxy_fixture(%{model_type: "stt"})
      {:ok, _provider} = Providers.update_provider(provider, %{dialect: dialect})

      conn =
        build_conn()
        |> authed_conn(token)
        |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
        |> post(~p"/v1/audio/transcriptions", stt_multipart(model.name, format))

      assert %{"error" => %{"code" => "unsupported_response_format", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "verbose_json"
      assert message =~ ~s("#{format}")

      # Zero upstream calls: the rejection happens before routing spends an
      # attempt, a credential or a hold.
      refute_receive {:provider_raw_body, _sent, _headers}, 50
    end
  end

  # The formats the wire DOES serve cross untouched, on both dialects.
  test "json and verbose_json reach the upstream unchanged" do
    for dialect <- ["openai", "openrouter"],
        format <- ["json", "verbose_json"] do
      %{token: token, model: model, provider: provider} = proxy_fixture(%{model_type: "stt"})
      {:ok, _provider} = Providers.update_provider(provider, %{dialect: dialect})
      body = stt_multipart(model.name, format)

      conn =
        build_conn()
        |> authed_conn(token)
        |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
        |> post(~p"/v1/audio/transcriptions", body)

      assert json_response(conn, 200)["text"] == "hola mundo"

      # The lane's upstream id differs from the client's name, so the body is
      # rebuilt — but the `response_format` the client asked for survives.
      assert_receive {:provider_raw_body, sent, _headers}
      assert sent =~ ~s(name="response_format"\r\n\r\n#{format})
    end
  end

  test "a binary upstream response reaches the client with its content-type", %{conn: conn} do
    %{token: token, model: model, member: member} =
      proxy_fixture(%{model_type: "tts", path_overrides: %{"tts" => "/binary-speech"}})

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola",
        "voice" => "af_heart"
      })

    # The bytes, not a JSON wrapper: `json/1` would have sent `{}`.
    assert conn.status == 200
    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x00>>
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"

    # The cost header survives the binary path (no upstream usage and no
    # manual pricing: the honest $0).
    assert get_resp_header(conn, "x-tokengate-cost") == ["0"]

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "tts"
    assert log.status_code == 200
  end

  # A binary answer can still report its cost — LiteLLM proxies put it in a
  # response HEADER, and there is no JSON body to read it from.
  test "a binary upstream response still books the header-reported cost", %{conn: conn} do
    %{
      token: token,
      model: model,
      member: member
    } =
      proxy_fixture(%{
        credit_units: 100,
        model_type: "tts",
        path_overrides: %{"tts" => "/costly-binary-speech"}
      })

    conn =
      conn
      |> authed_conn(token)
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola",
        "voice" => "af_heart"
      })

    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x01>>
    assert get_resp_header(conn, "x-tokengate-cost") == ["0.000420"]

    assert %{consumed_micro: 420} = Budgets.limit_spend({:user, member.user_id})

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == "tts"
    assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000420"))
  end

  # A tts client asks for audio, not JSON: the old `plug :accepts, ["json"]`
  # in the proxy pipeline refused it with a 406 before the controller ran.
  # The proxy mirrors the upstream's answer, so no negotiation happens here.
  test "an audio Accept header is not refused with 406", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{model_type: "tts", path_overrides: %{"tts" => "/binary-speech"}})

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("accept", "audio/mpeg")
      |> post(~p"/v1/audio/speech", %{
        "model" => model.name,
        "input" => "hola",
        "voice" => "af_heart"
      })

    assert response(conn, 200) == <<0xFF, 0xFB, 0x90, 0x00>>
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"
  end

  # The operator's override is the path the raw multipart body must reach:
  # the capture is transport, the path is routing — both have to line up.
  test "multipart passthrough honours the operator's path override", %{conn: conn} do
    %{token: token, model: model} =
      proxy_fixture(%{model_type: "stt", path_overrides: %{"stt" => "/custom/transcriptions"}})

    body = multipart_body(model.name)

    conn =
      conn
      |> authed_conn(token)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
      |> post(~p"/v1/audio/transcriptions", body)

    assert json_response(conn, 200)
    assert_receive {:provider_request_path, "/custom/transcriptions"}

    assert_receive {:provider_raw_body, received, _headers}
    assert_mapped_model(received, model.name)
  end

  # Drives one of the six services end to end and returns the conn: the
  # fixture's provider points at the test server, so the path the wire saw is
  # what `ProviderPaths` resolved for the service.
  defp assert_service_route(conn, gateway, upstream_path, request_type, body) do
    # The routing capability IS the model's type now: each service test
    # registers its model with the endpoint's own type.
    %{token: token, model: model, member: member} =
      proxy_fixture(%{model_type: request_type})

    conn =
      conn
      |> authed_conn(token)
      |> post(gateway, Map.merge(%{"model" => model.name}, body))

    assert json_response(conn, 200)

    assert_receive {:provider_request_path, ^upstream_path}
    assert_receive {:provider_request, received}

    # The client's own fields travel untouched; the model is rewritten to the
    # provider's own id.
    Enum.each(body, fn {key, value} -> assert received[key] == value end)
    assert received["model"] =~ "gpt-4o-real"

    assert %{success: 1} = Oban.drain_queue(queue: :logs)

    log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
    assert log.request_type == request_type
    assert log.status_code == 200

    conn
  end

  defp json_body(conn), do: json_response(conn, 200)

  # ---------------------------------------------------------------------------
  # P2 — el gate por sujeto: 0 es CERO, unlimited_spend explícito pasa
  # ---------------------------------------------------------------------------

  describe "gate por sujeto (límite mensual + top-ups)" do
    test "límite 0 (cero) bloquea con 402 y código propio", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{credit_units: 0})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 402)["error"]["code"] == "budget_exceeded"
      refute json_response(conn, 402)["error"]["message"] =~ "Global"
    end

    test "sin límite, sin ilimitado y sin top-ups: 402 con código no_credit", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{blocked: true})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      body = json_response(conn, 402)
      assert body["error"]["code"] == "no_credit"
      # Copy propio: NO comparte el mensaje del límite agotado ni el del cap global.
      refute body["error"]["message"] =~ "Monthly"
      refute body["error"]["message"] =~ "Global"
    end

    test "unlimited_spend pasa aunque no haya límite", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{unlimited: true})

      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)
    end

    test "límite agotado + top-up vigente: el request pasa y se debita el top-up", %{conn: conn} do
      %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 0})

      {:ok, topup} =
        Tokengate.Credits.Topups.create(%{"user_id" => member.user_id, "amount_usd" => "50.00"})

      # El límite es 0 (cero): sin top-up sería 402. Con top-up vigente el
      # request pasa y el log registra QUÉ se debitó.
      conn = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)
      assert %{success: 1} = Oban.drain_queue(queue: :logs)

      # El log asentado por ESTE request: el único con el monto exacto.
      log =
        Repo.one(
          from l in RequestLog,
            where: l.group_member_id == ^member.id,
            where: l.provider_cost_usd == ^Decimal.new("0.000150"),
            order_by: [desc: l.inserted_at],
            limit: 1
        )

      assert log.credit_topup_id == topup.id
      assert %{consumed_micro: 150} = Budgets.topup_spend(topup.id)
    end
  end

  ## El body no se contamina entre intentos ####################################
  #
  # El body que viaja a CADA upstream se reconstruye desde el payload ORIGINAL
  # del cliente: los overrides del model_provider (`extra_body`,
  # `omit_body_fields`), el dialecto de reasoning y las guard rails son
  # POR-UPSTREAM. Heredar el body ya reescrito mandaría lo inyectado por el
  # intento 1 al upstream del fallback —que 400ea en un campo que no
  # documenta— y apilaría las guard rails una vez por intento.
  describe "el body no se contamina entre intentos" do
    test "los overrides del intento caído NO viajan al upstream directo del fallback", %{
      conn: conn
    } do
      u = unique()
      # Intento 1: el lane del fixture, upstream caído, con overrides PROPIOS:
      # inyecta `service_tier` (extra_body) y omite `provider`, un campo crudo
      # que el cliente mandó.
      %{token: token, model: model} = proxy_fixture(%{down: true})
      [mp1] = Providers.list_model_providers(model.id)

      {:ok, _} =
        Providers.update_model_provider(mp1, %{
          extra_body: %{"service_tier" => "priority"},
          omit_body_fields: ["provider"]
        })

      # Intento 2: el fallback, un DIRECTO (Fireworks) sin overrides.
      cred2 = add_healthy_fallback(model, u)
      :ok = make_credential_provider_direct(cred2, "fireworks-ai")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "provider", "fireworks"))

      assert json_response(conn, 200)

      calls = provider_calls()
      first = for {payload, path} <- calls, String.contains?(path, "/down"), do: payload
      direct = for {payload, path} <- calls, not String.contains?(path, "/down"), do: payload

      assert first != [], "el intento 1 no llegó al upstream"

      # El body del intento 1 lleva LO SUYO: el campo omitido no viaja y el
      # inyectado sí.
      for payload <- first do
        refute Map.has_key?(payload, "provider"),
               "el omit_body_fields del intento 1 no se aplicó: #{inspect(payload["provider"])}"

        assert payload["service_tier"] == "priority"
      end

      assert direct != [], "el fallback no llegó al upstream directo"

      # El fallback reconstruye el body desde el payload del CLIENTE: el campo
      # crudo vuelve (el omit era del intento 1, no suyo) y lo inyectado por el
      # intento anterior no contamina.
      for payload <- direct do
        assert payload["provider"] == "fireworks"

        refute Map.has_key?(payload, "service_tier"),
               "el extra_body del intento 1 viajó al directo: #{inspect(payload["service_tier"])}"
      end
    end

    test "streaming: el fallback tampoco hereda el body del intento anterior", %{conn: conn} do
      u = unique()
      %{token: token, model: model} = proxy_fixture(%{down: true})
      [mp1] = Providers.list_model_providers(model.id)

      {:ok, _} =
        Providers.update_model_provider(mp1, %{
          extra_body: %{"service_tier" => "priority"},
          omit_body_fields: ["provider"]
        })

      cred2 = add_healthy_fallback(model, u)
      :ok = make_credential_provider_direct(cred2, "fireworks-ai")

      body =
        chat_body(model.name)
        |> Map.put("stream", true)
        |> Map.put("provider", "fireworks")

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", body)

      assert conn.state == :chunked
      assert response(conn, 200) =~ "[DONE]"

      calls = provider_calls()
      first = for {payload, path} <- calls, String.contains?(path, "/down"), do: payload
      direct = for {payload, path} <- calls, not String.contains?(path, "/down"), do: payload

      assert first != [], "el intento 1 no llegó al upstream"

      # El body del intento 1 lleva LO SUYO también en streaming.
      for payload <- first do
        refute Map.has_key?(payload, "provider"),
               "el omit_body_fields del intento 1 no se aplicó: #{inspect(payload["provider"])}"

        assert payload["service_tier"] == "priority"
      end

      assert direct != [], "el fallback no llegó al upstream directo"

      # Y el fallback reconstruye desde el payload del CLIENTE, igual que no-streaming.
      for payload <- direct do
        assert payload["provider"] == "fireworks"

        refute Map.has_key?(payload, "service_tier"),
               "el extra_body del intento 1 viajó al directo: #{inspect(payload["service_tier"])}"
      end
    end

    test "las guard rails se aplican UNA vez, no una por intento", %{conn: conn} do
      u = unique()
      %{token: token, model: model} = proxy_fixture(%{down: true})
      {:ok, _} = Providers.update_model(model, %{guard_rails: "REGLA"})
      add_healthy_fallback(model, u)

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", %{
          "model" => model.name,
          "messages" => [
            %{"role" => "system", "content" => "SYS"},
            %{"role" => "user", "content" => "hola"}
          ]
        })

      assert json_response(conn, 200)

      direct =
        for {payload, path} <- provider_calls(), not String.contains?(path, "/down"), do: payload

      assert direct != [], "el fallback no llegó al upstream"

      for payload <- direct do
        assert [%{"role" => "system", "content" => content} | _] = payload["messages"]
        assert content == "REGLA\n\nSYS", "guard rails duplicadas: #{inspect(content)}"
      end
    end
  end

  ## Costo del request en la respuesta (incluye el acierto de caché) ###########

  # El contrato de costo vale para TODO 2xx, no sólo para el primer request de
  # un payload: un acierto de caché local responde con `x-tokengate-cache: hit`
  # y el costo del request que SÍ llegó al upstream ($0 para este, que no lo
  # tocó), y un stream entrega el costo aunque el upstream no emita su frame de
  # usage.
  describe "cost contract on cached hits and silent streams" do
    test "chat: a cache hit answers 200 at $0 with the cost contract intact", %{conn: conn} do
      %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 100})
      body = chat_body(model.name)

      first = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
      assert json_response(first, 200)["usage"]["cost_usd"] > 0
      assert get_resp_header(first, "x-tokengate-cost") == ["0.000150"]
      assert_receive {:provider_request, _}

      # El store del cache es un cast: se sincroniza con el GenServer para que
      # el segundo request no pueda adelantársele.
      _ = :sys.get_state(ResponseCache)

      second = conn |> recycle() |> authed_conn(token) |> post(~p"/v1/chat/completions", body)

      # Sin segunda llamada al upstream: la respuesta salió del cache.
      refute_receive {:provider_request, _}, 300

      hit = json_response(second, 200)

      assert get_resp_header(second, "x-tokengate-cache") == ["hit"]
      assert get_resp_header(second, "x-tokengate-cost") == ["0"]
      assert hit["usage"]["cost_usd"] == 0.0
      # El contenido servido es el del upstream, intacto.
      assert get_in(hit, ["choices", Access.at(0), "message", "content"]) == "qué onda"

      # El hit no debita nada: sigue el gasto del primer request (150 micro-USD
      # = el costo real que reportó el upstream).
      assert %{consumed_micro: 150} = Budgets.limit_spend({:user, member.user_id})
    end

    test "chat: a cache hit books a $0 row and counts in the realtime collector", %{conn: conn} do
      %{token: token, model: model, member: member} = proxy_fixture(%{credit_units: 100})
      body = chat_body(model.name)

      before = Tokengate.Metrics.Collector.snapshot_lite()

      first = conn |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
      assert json_response(first, 200)
      assert_receive {:provider_request, _}

      _ = :sys.get_state(ResponseCache)

      second = conn |> recycle() |> authed_conn(token) |> post(~p"/v1/chat/completions", body)
      assert get_resp_header(second, "x-tokengate-cache") == ["hit"]
      refute_receive {:provider_request, _}, 100

      # M10: el hit dejaba de existir para la contabilidad. Ahora deja fila
      # durable con costo $0 / 0 tokens (nada se consumió aguas arriba) y sin
      # top-up — el hold se LIBERA, no se debita.
      assert %{success: 2} = Oban.drain_queue(queue: :logs)

      rows =
        Repo.all(
          from l in RequestLog,
            where: l.group_member_id == ^member.id,
            order_by: [asc: l.inserted_at, asc: l.id]
        )

      assert length(rows) == 2

      hit = Enum.find(rows, &(&1.prompt_tokens == 0))
      assert hit.status_code == 200
      assert hit.streaming == false
      # Durable marker: the cache hit is the ONLY row flagged; the request
      # that filled the cache (and paid the upstream) is not.
      assert hit.cache_hit == true
      assert Enum.find(rows, &(&1.id != hit.id)).cache_hit == false
      assert hit.completion_tokens == 0
      assert hit.credit_topup_id == nil
      assert Decimal.equal?(hit.provider_cost_usd, Decimal.new(0))

      # Y cuenta como request en el collector en vivo (2: miss + hit).
      after_run = Tokengate.Metrics.Collector.snapshot_lite()
      assert after_run.requests_total == before.requests_total + 2
    end

    test "embeddings: a cache hit keeps the passthrough body and reports $0", %{conn: conn} do
      %{token: token, model: model} = proxy_fixture(%{credit_units: 100})
      update_alias_type(model, "embedding")
      body = %{"model" => model.name, "input" => ["hola", "wey"]}

      first = conn |> authed_conn(token) |> post(~p"/v1/embeddings", body)
      first_body = json_response(first, 200)

      # Un servicio viaja intacto: el costo NO se le inyecta al body.
      assert_in_delta first_body["usage"]["cost"], 0.000011, 1.0e-9
      refute Map.has_key?(first_body, "cost_usd")
      assert get_resp_header(first, "x-tokengate-cost") == ["0.000011"]
      assert_receive {:provider_request, _}

      _ = :sys.get_state(ResponseCache)

      second = conn |> recycle() |> authed_conn(token) |> post(~p"/v1/embeddings", body)
      refute_receive {:provider_request, _}, 300

      hit = json_response(second, 200)

      assert get_resp_header(second, "x-tokengate-cache") == ["hit"]
      assert get_resp_header(second, "x-tokengate-cost") == ["0"]
      # Byte por byte el mismo body que sirvió el upstream: el hit no le agrega
      # el `cost_usd` que un servicio nunca lleva.
      assert hit == first_body
    end

    test "stream: a silent upstream still gets a closing usage frame with the cost", %{
      conn: conn
    } do
      %{token: token, model: model, member: member, model_provider: model_provider} =
        proxy_fixture(%{credit_units: 100, path_overrides: %{"chat" => "/nousagestream"}})

      # Precio manual: el upstream no reporta NADA, así que el costo del
      # request sale de la cadena de fallback y debe ser > 0.
      {:ok, _} =
        Providers.update_model_provider(model_provider, %{
          input_cost_per_million: "2.50",
          output_cost_per_million: "10.00"
        })

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

      frames = conn |> response(200) |> String.split("\n\n", trim: true)

      # El contenido del upstream pasó intacto y el [DONE] sigue cerrando.
      assert Enum.at(frames, 0) =~ ~s("content":"qué")
      assert List.last(frames) == "data: [DONE]"

      # TokenGate emite el frame de cierre: un solo frame con usage, con el
      # costo del request.
      assert [usage_frame] = Enum.filter(frames, &(&1 =~ "\"usage\""))
      closing = usage_frame |> String.trim_leading("data: ") |> Jason.decode!()

      assert closing["choices"] == []
      # El modelo es el que sirvió el upstream (el mismo que ecoan sus propios
      # frames), no el alias que pidió el cliente.
      assert closing["model"] == model_provider.provider_model
      assert closing["usage"]["cost_usd"] > 0

      # Y el costo que ve el cliente es el mismo que se contabilizó.
      assert %{success: 1} = Oban.drain_queue(queue: :logs)
      log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)

      assert_in_delta closing["usage"]["cost_usd"],
                      Decimal.to_float(log.provider_cost_usd),
                      1.0e-9
    end

    test "stream: a header-only cost from the upstream rides the closing frame", %{conn: conn} do
      %{token: token, model: model, member: member} =
        proxy_fixture(%{credit_units: 100, path_overrides: %{"chat" => "/headercoststream"}})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

      frames = conn |> response(200) |> String.split("\n\n", trim: true)

      assert [usage_frame] = Enum.filter(frames, &(&1 =~ "\"usage\""))
      closing = usage_frame |> String.trim_leading("data: ") |> Jason.decode!()

      # El costo es el que reportó el upstream en su header, no un $0.
      assert_in_delta closing["usage"]["cost_usd"], 0.00042, 1.0e-9

      assert %{success: 1} = Oban.drain_queue(queue: :logs)
      log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
      assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000420"))
    end

    test "non-streaming: SurplusIntelligence buyer_cost_micro / x-si-buyer-cost-micro records real cost",
         %{conn: conn} do
      %{token: token, model: model, member: member} =
        proxy_fixture(%{credit_units: 100, path_overrides: %{"chat" => "/simicro"}})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", chat_body(model.name))

      body = json_response(conn, 200)
      assert [cost_header] = get_resp_header(conn, "x-tokengate-cost")
      assert cost_header == "0.000017"
      assert_in_delta body["usage"]["cost_usd"], 0.000017, 1.0e-9

      assert %{success: 1} = Oban.drain_queue(queue: :logs)
      log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
      assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000017"))
    end

    test "streaming: SurplusIntelligence buyer_cost_micro wins over raw usage.cost and records real cost",
         %{conn: conn} do
      %{token: token, model: model, member: member} =
        proxy_fixture(%{credit_units: 100, path_overrides: %{"chat" => "/simicrostream"}})

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", Map.put(chat_body(model.name), "stream", true))

      frames = conn |> response(200) |> String.split("\n\n", trim: true)
      assert [usage_frame] = Enum.filter(frames, &(&1 =~ "\"usage\""))
      closing = usage_frame |> String.trim_leading("data: ") |> Jason.decode!()

      assert_in_delta closing["usage"]["cost_usd"], 0.000082, 1.0e-9

      assert %{success: 1} = Oban.drain_queue(queue: :logs)
      log = Repo.one(from l in RequestLog, where: l.group_member_id == ^member.id)
      assert Decimal.equal?(log.provider_cost_usd, Decimal.new("0.000082"))
    end
  end

  describe "fallback Gate 2 release and 429 exclusion" do
    test "fallback releases credential Gate 2 concurrency slot when moving to secondary", %{
      conn: conn
    } do
      u = unique()

      %{token: token, model: model, provider: prov1, credential: primary_cred} =
        proxy_fixture(%{down: true})

      {:ok, _prov1} = Providers.update_provider(prov1, %{max_concurrent: 1})

      {:ok, prov2} =
        Providers.create_provider(%{
          name: "Healthy Gate2 #{u}",
          base_url: upstream_url()
        })

      {:ok, cred2} =
        Providers.create_credential(%{provider_id: prov2.id, api_key_encrypted: "sk-g2-#{u}"})

      {:ok, _mp2} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: cred2.id,
          provider_model: "gpt-4o-g2",
          priority: 2
        })

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)

      # Credential 1's Gate 2 concurrency slot must be back at 0 (no leak).
      assert :ok =
               Tokengate.Limits.Manager.acquire_concurrency(primary_cred.id, 1)

      Tokengate.Limits.Manager.release_concurrency(primary_cred.id)
    end

    test "429 excludes credential immediately after 1st attempt without retrying same key", %{
      conn: conn
    } do
      u = unique()

      %{token: token, model: model, credential: primary_cred} =
        proxy_fixture(%{path_overrides: %{"chat" => "/ratelimited"}})

      {:ok, prov2} =
        Providers.create_provider(%{
          name: "Healthy 429 Fallback #{u}",
          base_url: upstream_url()
        })

      {:ok, cred2} =
        Providers.create_credential(%{
          provider_id: prov2.id,
          api_key_encrypted: "sk-429-fb-#{u}"
        })

      {:ok, _mp2} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: cred2.id,
          provider_model: "gpt-4o-429-fb",
          priority: 2
        })

      conn =
        conn
        |> authed_conn(token)
        |> post(~p"/v1/chat/completions", chat_body(model.name))

      assert json_response(conn, 200)

      # Only 1 deferred fallback log for primary_cred (no wasted retry on 429) + 1 success for cred2.
      assert %{success: 2} = Oban.drain_queue(queue: :logs)

      fallback_logs =
        Repo.all(
          from l in RequestLog,
            where: l.model_id == ^model.id and l.credential_id == ^primary_cred.id
        )

      assert length(fallback_logs) == 1
      assert hd(fallback_logs).error_reason == "provider_rate_limited"
    end
  end
end
