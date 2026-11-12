defmodule TokengateWeb.OAuth.GoogleTest do
  @moduledoc """
  Borde del Alto 1 (takeover de cuenta): `fetch_userinfo/1` sólo puede devolver
  el perfil cuando Google confirma el correo verificado. El link por email de
  `Accounts.find_or_create_from_google/1` convierte un correo no verificado en
  control de la cuenta de la víctima.
  """

  use ExUnit.Case, async: false

  alias TokengateWeb.OAuth.Google

  @port 41337

  defmodule UserinfoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      body = :persistent_term.get({__MODULE__, :body}, %{})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    original = Application.get_env(:tokengate, :google_oauth)

    Application.put_env(
      :tokengate,
      :google_oauth,
      original
      |> Keyword.put(:userinfo_url, "http://localhost:#{@port}/userinfo")
    )

    start_supervised!({Bandit, plug: UserinfoPlug, scheme: :http, ip: :loopback, port: @port})

    on_exit(fn ->
      Application.put_env(:tokengate, :google_oauth, original)
      :persistent_term.erase({UserinfoPlug, :body})
    end)

    :ok
  end

  defp body(attrs) do
    :persistent_term.put(
      {UserinfoPlug, :body},
      Map.merge(
        %{
          "id" => "google-sub-1",
          "email" => "victim@example.com",
          "name" => "Victim",
          "picture" => "https://example.com/a.png"
        },
        attrs
      )
    )
  end

  test "verified_email: true devuelve el perfil" do
    body(%{"verified_email" => true})

    assert {:ok, %{google_id: "google-sub-1", email: "victim@example.com"}} =
             Google.fetch_userinfo("token")
  end

  test "email_verified: true (userinfo OpenID) también devuelve el perfil" do
    body(%{"email_verified" => true})

    assert {:ok, %{email: "victim@example.com"}} = Google.fetch_userinfo("token")
  end

  test "verified_email: false NO devuelve el perfil" do
    body(%{"verified_email" => false})

    assert {:error, :email_not_verified} = Google.fetch_userinfo("token")
  end

  test "sin marca de verificación NO devuelve el perfil (fail-closed)" do
    body(%{})

    assert {:error, :email_not_verified} = Google.fetch_userinfo("token")
  end

  test "un string \"true\" no cuenta como verificado" do
    body(%{"verified_email" => "true", "email_verified" => "true"})

    assert {:error, :email_not_verified} = Google.fetch_userinfo("token")
  end
end
