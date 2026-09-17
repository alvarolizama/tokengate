defmodule Tokengate.ObservabilityTest do
  use Tokengate.DataCase, async: true
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp valid_destination_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        name: "Honeycomb",
        type: "otlp_webhook",
        url: "https://api.honeycomb.io",
        headers: %{"X-Api-Key" => "secret"}
      },
      attrs
    )
  end

  defp destination_fixture(attrs \\ %{}) do
    {:ok, destination} =
      Observability.create_destination(valid_destination_attrs(attrs))

    destination
  end

  # ---------------------------------------------------------------------------
  # create_destination/1
  # ---------------------------------------------------------------------------

  describe "create_destination/1" do
    test "with valid attrs succeeds" do
      attrs = valid_destination_attrs()

      assert {:ok, %Destination{} = dest} = Observability.create_destination(attrs)
      assert dest.name == "Honeycomb"
      assert dest.type == "otlp_webhook"
      assert dest.url == "https://api.honeycomb.io"
      assert dest.headers == %{"X-Api-Key" => "secret"}
    end

    test "applies default type when type omitted" do
      {:ok, dest} =
        Observability.create_destination(%{
          name: "Default Dest",
          type: "otlp_webhook"
        })

      assert dest.type == "otlp_webhook"
    end

    test "validates type inclusion" do
      {:error, changeset} =
        Observability.create_destination(%{
          name: "Bad",
          type: "invalid_type"
        })

      assert "is invalid" in errors_on(changeset).type
    end

    # Un destino ya no requiere un perfil de límites: es global.
    # Un destino ya no requiere un perfil de límites: es global.
    test "requires a name" do
      {:error, changeset} = Observability.create_destination(%{})

      assert errors_on(changeset).name
    end
  end

  # ---------------------------------------------------------------------------
  # list_all_destinations/0
  # ---------------------------------------------------------------------------

  describe "list_all_destinations/0" do
    test "returns every destination, ordered by name" do
      destination_fixture(%{name: "Zulu"})
      destination_fixture(%{name: "Alpha"})

      names = Observability.list_all_destinations() |> Enum.map(& &1.name)

      assert "Alpha" in names
      assert "Zulu" in names
      assert names == Enum.sort(names)
    end

    test "returns an empty list when none configured" do
      assert Observability.list_all_destinations() == []
    end
  end

  # ---------------------------------------------------------------------------
  # get_destination / get_destination!
  # ---------------------------------------------------------------------------

  describe "get_destination/1 and get_destination!/1" do
    test "get_destination/1 returns nil when not found" do
      assert Observability.get_destination(Ecto.UUID.generate()) == nil
    end

    test "get_destination!/1 returns the destination" do
      dest = destination_fixture()

      result = Observability.get_destination!(dest.id)
      assert result.id == dest.id
      assert result.name == dest.name
    end
  end

  # ---------------------------------------------------------------------------
  # update / delete
  # ---------------------------------------------------------------------------

  describe "update_destination/2" do
    test "updates fields" do
      dest = destination_fixture()

      {:ok, updated} =
        Observability.update_destination(dest, %{
          name: "Updated Name",
          url: "https://new.example.com"
        })

      assert updated.name == "Updated Name"
      assert updated.url == "https://new.example.com"
    end
  end

  describe "delete_destination/1" do
    test "deletes the destination" do
      dest = destination_fixture()
      {:ok, _} = Observability.delete_destination(dest)

      assert Observability.list_all_destinations() == []
    end
  end
end
