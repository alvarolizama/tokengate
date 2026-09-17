defmodule Tokengate.Accounts.ServiceApiKeysTest do
  @moduledoc """
  Un servicio tiene **N claves activas con etiqueta**, igual que un usuario
  (homologación de UX). Estas invariantes son las que sostienen la paridad:

    1. Todas las claves de un servicio autentican y `get_service_by_api_key/1`
       devuelve la clave **presentada** precargada (el proxy llavea el bucket de
       límites y la atribución del log por esa key: devolver otra sería un bug
       silencioso).
    2. Revocar una clave no afecta a las demás.
    3. Borrar el servicio borra **todas** sus claves (ninguna huérfana).
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts

  defp service_fixture do
    {:ok, service} =
      Accounts.create_service(%{name: "Svc #{System.unique_integer([:positive])}"})

    service
  end

  defp key_fixture(service, label) do
    {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

    {:ok, key} =
      Accounts.create_api_key(%{
        "subject_type" => "service",
        "service_id" => service.id,
        "key_hash" => key_hash,
        "key_prefix" => key_prefix,
        "label" => label
      })

    {token, key}
  end

  test "cada una de las N claves autentica y la presentada llega precargada" do
    service = service_fixture()
    {t1, k1} = key_fixture(service, "uno")
    {t2, k2} = key_fixture(service, "dos")

    assert {:ok, found1} = Accounts.get_service_by_api_key(t1)
    assert found1.id == service.id
    assert found1.api_key.key_prefix == k1.key_prefix

    assert {:ok, found2} = Accounts.get_service_by_api_key(t2)
    assert found2.api_key.key_prefix == k2.key_prefix
  end

  test "revocar una clave no afecta a las demás" do
    service = service_fixture()
    {t1, k1} = key_fixture(service, "revocar")
    {t2, _k2} = key_fixture(service, "seguir")

    assert {:ok, _} = Accounts.revoke_service_api_key(k1)

    assert Accounts.get_service_by_api_key(t1) == {:error, :not_found}
    assert {:ok, _service} = Accounts.get_service_by_api_key(t2)

    labels =
      Accounts.list_api_keys_for_service(service.id) |> Enum.map(& &1.label)

    assert labels == ["seguir"]
  end

  test "borrar el servicio borra todas sus claves" do
    service = service_fixture()
    {_t1, k1} = key_fixture(service, "una")
    {_t2, k2} = key_fixture(service, "otra")

    assert {:ok, _} = Accounts.delete_service(service)

    assert Accounts.get_service(service.id) == nil
    assert Accounts.get_api_key(k1.id) == nil
    assert Accounts.get_api_key(k2.id) == nil
  end
end
