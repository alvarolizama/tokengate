defmodule Tokengate.Accounts.ApiKeysPerSubjectTest do
  @moduledoc """
  W3: API keys múltiples por sujeto con label, resolución del plug por la key
  del usuario y consumo agregable por key (claim P4).

  Cubre:

    * N keys activas del mismo usuario con labels distintos, y que revocar una
      no afecta a las otras;
    * `get_group_member_by_api_key/1` resolviendo la **membresía** del usuario
      dueño de la key (el proxy sigue recibiendo un `GroupMember`);
    * `spend_by_api_key/2` agregando el consumo desde `request_logs.api_key_id`;
    * la invalidación de caché al crear una key (por hash y por sujeto).
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Logs}
  alias Tokengate.Accounts.ApiKeyCache

  setup do
    # El cache es un ETS nombrado (singleton): se limpia entre tests.
    if :ets.whereis(ApiKeyCache.table()) != :undefined do
      :ets.delete_all_objects(ApiKeyCache.table())
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp user_fixture do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "keys-#{unique}@example.com",
        "name" => "Keys #{unique}",
        "password" => "ValidPassword123"
      })

    user
  end

  defp group_fixture do
    {:ok, group} =
      Accounts.create_group(%{"name" => "G#{System.unique_integer([:positive])}", "unlimited_spend" => true})

    group
  end

  defp member_fixture(user, group) do
    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    member
  end

  defp service_fixture do
    {:ok, service} =
      Accounts.create_service(%{"name" => "S#{System.unique_integer([:positive])}"})

    service
  end

  defp create_key_for(user, label) do
    {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

    {:ok, key} =
      Accounts.create_api_key(%{
        "subject_type" => "member",
        "user_id" => user.id,
        "key_hash" => key_hash,
        "key_prefix" => key_prefix,
        "label" => label
      })

    {key, token}
  end

  # ---------------------------------------------------------------------------
  # N keys activas con label
  # ---------------------------------------------------------------------------

  describe "N keys activas por usuario" do
    test "un usuario puede tener varias keys activas con labels distintos" do
      user = user_fixture()
      {k1, _t1} = create_key_for(user, "ci")
      {k2, _t2} = create_key_for(user, "laptop")
      {k3, _t3} = create_key_for(user, "server")

      keys = Accounts.list_api_keys_for_user(user.id)
      ids = Enum.map(keys, & &1.id)
      labels = Enum.map(keys, & &1.label) |> Enum.sort()

      assert length(keys) == 3
      assert k1.id in ids and k2.id in ids and k3.id in ids
      assert labels == ["ci", "laptop", "server"]
    end

    test "revocar una key no afecta a las otras" do
      user = user_fixture()
      {k1, t1} = create_key_for(user, "revocar")
      {_k2, t2} = create_key_for(user, "seguir-1")
      {_k3, t3} = create_key_for(user, "seguir-2")

      assert {:ok, revoked} = Accounts.revoke_api_key(k1)
      assert revoked.status == "revoked"

      # La revocada ya no resuelve…
      assert {:error, :not_found} = Accounts.get_group_member_by_api_key(t1)

      # …y las otras siguen vivas.
      activas = Accounts.list_api_keys_for_user(user.id)
      assert length(activas) == 2
      refute k1.id in Enum.map(activas, & &1.id)

      _ = {t2, t3}
    end

    test "un servicio también puede tener N keys activas con label" do
      service = service_fixture()

      for label <- ["ingest", "worker"] do
        {_token, hash, prefix} = Accounts.generate_api_key_material()

        {:ok, _} =
          Accounts.create_api_key(%{
            "subject_type" => "service",
            "service_id" => service.id,
            "key_hash" => hash,
            "key_prefix" => prefix,
            "label" => label
          })
      end

      keys = Accounts.list_api_keys_for_service(service.id)

      assert length(keys) == 2
      assert Enum.map(keys, & &1.label) |> Enum.sort() == ["ingest", "worker"]
    end
  end

  # ---------------------------------------------------------------------------
  # Resolución del plug: la key es del usuario, el plug devuelve la membresía
  # ---------------------------------------------------------------------------

  describe "get_group_member_by_api_key/1" do
    test "resuelve la membresía del usuario dueño de la key" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(user, group)
      {_key, token} = create_key_for(user, "plug")

      assert {:ok, resolved} = Accounts.get_group_member_by_api_key(token)
      assert resolved.id == member.id
      assert resolved.user_id == user.id
      assert resolved.group_id == group.id
      # La asociación queda cargada para el proxy (group/user) y la key
      # resuelta viaja en la membresía.
      assert resolved.api_key
    end

    test "dos keys del mismo usuario resuelven a la MISMA membresía" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(user, group)
      {_k1, t1} = create_key_for(user, "a")
      {_k2, t2} = create_key_for(user, "b")

      assert {:ok, m1} = Accounts.get_group_member_by_api_key(t1)
      assert {:ok, m2} = Accounts.get_group_member_by_api_key(t2)

      assert m1.id == member.id
      assert m2.id == member.id
    end

    test "un token desconocido no resuelve" do
      assert {:error, :not_found} = Accounts.get_group_member_by_api_key("tg-no-existe")
    end
  end

  # ---------------------------------------------------------------------------
  # Consumo por key (P4)
  # ---------------------------------------------------------------------------

  describe "spend_by_api_key/2" do
    test "agrega requests y costo por key desde request_logs.api_key_id" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(user, group)
      {k1, _t1} = create_key_for(user, "medida")

      # Dos requests con esa key.
      for cost <- ["1.50", "0.50"] do
        {:ok, _} =
          Logs.log_request(%{
            group_member_id: member.id,
            subject_type: "user",
            model_requested: "test-model",
            provider_cost_usd: cost,
            api_key_id: k1.id,
            api_key_prefix: k1.key_prefix
          })
      end

      spend = Accounts.spend_by_api_key([k1.id])

      assert %{requests: 2, cost_usd: cost} = Map.fetch!(spend, k1.id)
      assert Decimal.equal?(cost, Decimal.new("2.00"))
    end

    test "una key sin tráfico no aparece en el mapa" do
      user = user_fixture()
      {k1, _} = create_key_for(user, "sin-trafico")

      assert Accounts.spend_by_api_key([k1.id]) == %{}
    end

    test "el consumo se puede acotar por ventana" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(user, group)
      {k1, _} = create_key_for(user, "ventana")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          subject_type: "user",
          model_requested: "m",
          provider_cost_usd: "5.00",
          api_key_id: k1.id,
          inserted_at: DateTime.add(now, -3600, :second)
        })

      desde = DateTime.add(now, -60, :second)

      assert Accounts.spend_by_api_key([k1.id], desde) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Invalidación de caché
  # ---------------------------------------------------------------------------

  describe "invalidación del ApiKeyCache al crear una key" do
    test "crear una key tumba el entry del usuario en el cache" do
      user = user_fixture()
      group = group_fixture()
      _member = member_fixture(user, group)

      # Se resuelve de verdad (llena el cache con la forma REAL del entry) y
      # luego se crea otra key: la invalidación por `user_id` debe tumbar la
      # entrada anterior.
      {_k0, t0} = create_key_for(user, "previa")
      hash0 = Accounts.hash_api_key(t0)

      assert %{member: _} = Accounts.resolve_auth_by_api_key(t0)
      assert :ets.lookup(ApiKeyCache.table(), hash0) != []

      {_k1, _t1} = create_key_for(user, "nueva")

      assert :ets.lookup(ApiKeyCache.table(), hash0) == []
    end
  end
end
