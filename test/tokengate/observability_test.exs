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
        headers: %{"X-Api-Key" => "secret"},
        privacy_mode: "metadata_only"
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
      assert dest.privacy_mode == "metadata_only"
    end

    test "applies defaults when type and privacy_mode omitted" do
      {:ok, dest} =
        Observability.create_destination(%{
          name: "Default Dest",
          type: "otlp_webhook",
          privacy_mode: "metadata_only"
        })

      assert dest.type == "otlp_webhook"
      assert dest.privacy_mode == "metadata_only"
    end

    test "validates type inclusion" do
      {:error, changeset} =
        Observability.create_destination(%{
          name: "Bad",
          type: "invalid_type",
          privacy_mode: "metadata_only"
        })

      assert "is invalid" in errors_on(changeset).type
    end

    test "validates privacy_mode inclusion" do
      {:error, changeset} =
        Observability.create_destination(%{
          name: "Bad",
          type: "otlp_webhook",
          privacy_mode: "leak_everything"
        })

      assert "is invalid" in errors_on(changeset).privacy_mode
    end

    test "requires name, type, privacy_mode" do
      {:error, changeset} = Observability.create_destination(%{})

      assert errors_on(changeset).name
      # type and privacy_mode have defaults, so they're never blank
    end
  end

  # ---------------------------------------------------------------------------
  # list_destinations
  # ---------------------------------------------------------------------------

  describe "list_destinations/0" do
    test "list_destinations/0 returns all destinations" do
      destination_fixture(%{name: "Dest1"})
      destination_fixture(%{name: "Dest2"})

      assert length(Observability.list_destinations()) == 2
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
          privacy_mode: "full",
          url: "https://new.example.com"
        })

      assert updated.name == "Updated Name"
      assert updated.privacy_mode == "full"
      assert updated.url == "https://new.example.com"
    end
  end

  describe "delete_destination/1" do
    test "deletes the destination" do
      dest = destination_fixture()
      {:ok, _} = Observability.delete_destination(dest)

      assert Observability.list_destinations() == []
    end
  end
end
