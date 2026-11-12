defmodule TokengateWeb.Plugs.ApiAuthRateLimitTest do
  @moduledoc """
  Auditoría medio: un token BIEN FORMADO pero falso pasa `ProxyPreAuth` y paga
  dos queries en `ApiAuth` (el cache de auth no cachea fallos). El cubo por IP
  reusa el ETS del login y sólo cuenta los intentos fallidos.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts
  alias TokengateWeb.Plugs.LoginRateLimit

  # Formato que emite el gateway: "tg-" + base64url de 24 bytes. `ProxyPreAuth`
  # lo deja pasar y la resolución falla en `ApiAuth` (la ruta que se limita).
  @bogus_token "tg-" <> String.duplicate("A", 24)

  @ip_key {:api_auth_ip, "127.0.0.1"}

  setup do
    original = Application.get_env(:tokengate, :api_auth_invalid_max_per_ip)
    Application.put_env(:tokengate, :api_auth_invalid_max_per_ip, 2)

    LoginRateLimit.TableKeeper.clear(@ip_key)

    on_exit(fn ->
      LoginRateLimit.TableKeeper.clear(@ip_key)

      if original do
        Application.put_env(:tokengate, :api_auth_invalid_max_per_ip, original)
      else
        Application.delete_env(:tokengate, :api_auth_invalid_max_per_ip)
      end
    end)

    :ok
  end

  defp post_with_token(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/v1/chat/completions", Jason.encode!(%{"model" => "gpt-4o", "messages" => []}))
  end

  test "los tokens falsos bien formados se cortan con 429 al agotar el cubo", %{conn: conn} do
    for _ <- 1..2 do
      response = post_with_token(conn, @bogus_token)
      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(response, 401)
    end

    blocked = post_with_token(conn, @bogus_token)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(blocked, 429)
    assert [retry_after] = get_resp_header(blocked, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "una key válida nunca consume el cubo de fallos", %{conn: conn} do
    token = token_fixture()

    # 3 fallos dejan el cubo agotado (max = 2)...
    for _ <- 1..3, do: post_with_token(conn, @bogus_token)

    assert %{"error" => %{"code" => "rate_limited"}} =
             json_response(post_with_token(conn, @bogus_token), 429)

    # ...y la key buena sigue autenticando: el path válido no toca el cubo.
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/v1/models")

    assert json_response(response, 200)
  end

  defp token_fixture do
    u = System.unique_integer([:positive])

    {:ok, group} =
      Accounts.create_group(%{
        "name" => "ApiAuth Limit #{u}",
        "default_rpm_limit" => 60,
        "default_concurrency_limit" => 5
      })

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "apiauth-limit-#{u}@example.com",
        "name" => "ApiAuth Limit #{u}",
        "password" => "apiauth-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    {:ok, _key, token} = Accounts.replace_api_key(member)

    token
  end
end
