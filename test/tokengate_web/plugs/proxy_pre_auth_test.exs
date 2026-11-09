defmodule TokengateWeb.Plugs.ProxyPreAuthTest do
  @moduledoc """
  Hallazgo Alto 5 de la auditoría: el endpoint leía hasta 10 MB del cuerpo de
  `/v1` antes de autenticar, y cada token inválido costaba una query (el cache
  de auth no cachea fallos). El guard corta el request sin credencial antes de
  `read_body/2`, con el mismo shape de error que `ApiAuth`.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts

  defp token_fixture do
    u = System.unique_integer([:positive])

    {:ok, group} =
      Accounts.create_group(%{
        "name" => "PreAuth #{u}",
        "default_rpm_limit" => 60,
        "default_concurrency_limit" => 5
      })

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "preauth-#{u}@example.com",
        "name" => "PreAuth #{u}",
        "password" => "preauth-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    {:ok, _key, token} = Accounts.replace_api_key(member)

    token
  end

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  test "sin Authorization: 401 y el body no se parsea", %{conn: conn} do
    conn = post_json(conn, ~p"/v1/chat/completions", %{"model" => "gpt-4o", "messages" => []})

    assert conn.status == 401
    assert %{"error" => %{"code" => "missing_api_key"}} = Jason.decode!(conn.resp_body)

    # La prueba de que el guard corre ANTES del parser: el body sigue sin tocar.
    assert %Plug.Conn.Unfetched{} = conn.body_params
    refute Map.has_key?(conn.private, :tokengate_raw_body)
  end

  test "bearer con formato imposible: 401 invalid_api_key, sin parsear", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer basura")
      |> post_json(~p"/v1/chat/completions", %{"model" => "gpt-4o"})

    assert conn.status == 401
    assert %{"error" => %{"code" => "invalid_api_key"}} = Jason.decode!(conn.resp_body)
    assert %Plug.Conn.Unfetched{} = conn.body_params
  end

  test "un header sin el scheme Bearer también es missing", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", token_fixture())
      |> post_json(~p"/v1/chat/completions", %{"model" => "gpt-4o"})

    assert conn.status == 401
    assert %{"error" => %{"code" => "missing_api_key"}} = Jason.decode!(conn.resp_body)
  end

  test "una key con el formato del gateway pasa y ApiAuth la resuelve", %{conn: conn} do
    token = token_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/v1/models")

    assert conn.status == 200
    assert %{"object" => "list", "data" => models} = Jason.decode!(conn.resp_body)
    assert is_list(models)
  end

  test "/health no pasa por el guard", %{conn: conn} do
    assert get(conn, ~p"/health").status == 200
  end
end
