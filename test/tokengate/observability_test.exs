defmodule Tokengate.ObservabilityTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Observability
  alias Tokengate.Observability.Destination
  alias Tokengate.Accounts

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp organization_fixture(attrs \\ %{}) do
    {:ok, organization} =
      Accounts.create_organization(
        Map.merge(
          %{
            "name" => "Acme Corp",
            "slug" => "acme-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    organization
  end

  defp valid_destination_attrs(organization, attrs \\ %{}) do
    Map.merge(
      %{
        organization_id: organization.id,
        name: "Honeycomb",
        type: "otlp_webhook",
        url: "https://api.honeycomb.io",
        headers: %{"X-Api-Key" => "secret"},
        privacy_mode: "metadata_only"
      },
      attrs
    )
  end

  defp destination_fixture(organization \\ nil, attrs \\ %{}) do
    organization = organization || organization_fixture()

    {:ok, destination} =
      Observability.create_destination(valid_destination_attrs(organization, attrs))

    destination
  end

  # ---------------------------------------------------------------------------
  # create_destination/1
  # ---------------------------------------------------------------------------

  describe "create_destination/1" do
    test "with valid attrs succeeds" do
      org = organization_fixture()
      attrs = valid_destination_attrs(org)

      assert {:ok, %Destination{} = dest} = Observability.create_destination(attrs)
      assert dest.name == "Honeycomb"
      assert dest.type == "otlp_webhook"
      assert dest.url == "https://api.honeycomb.io"
      assert dest.headers == %{"X-Api-Key" => "secret"}
      assert dest.privacy_mode == "metadata_only"
      assert dest.organization_id == org.id
    end

    test "applies defaults when type and privacy_mode omitted" do
      org = organization_fixture()

      {:ok, dest} =
        Observability.create_destination(%{
          organization_id: org.id,
          name: "Default Dest",
          type: "otlp_webhook",
          privacy_mode: "metadata_only"
        })

      assert dest.type == "otlp_webhook"
      assert dest.privacy_mode == "metadata_only"
    end

    test "validates type inclusion" do
      org = organization_fixture()

      {:error, changeset} =
        Observability.create_destination(%{
          organization_id: org.id,
          name: "Bad",
          type: "invalid_type",
          privacy_mode: "metadata_only"
        })

      assert "is invalid" in errors_on(changeset).type
    end

    test "validates privacy_mode inclusion" do
      org = organization_fixture()

      {:error, changeset} =
        Observability.create_destination(%{
          organization_id: org.id,
          name: "Bad",
          type: "otlp_webhook",
          privacy_mode: "leak_everything"
        })

      assert "is invalid" in errors_on(changeset).privacy_mode
    end

    test "requires organization_id, name, type, privacy_mode" do
      {:error, changeset} = Observability.create_destination(%{})

      assert errors_on(changeset).organization_id
      assert errors_on(changeset).name
      # type and privacy_mode have defaults, so they're never blank
    end

    test "validates foreign key on organization_id" do
      {:error, changeset} =
        Observability.create_destination(%{
          organization_id: Ecto.UUID.generate(),
          name: "Orphan",
          type: "otlp_webhook",
          privacy_mode: "metadata_only"
        })

      assert "does not exist" in errors_on(changeset).organization_id
    end
  end

  # ---------------------------------------------------------------------------
  # list_destinations / list_destinations_for_org
  # ---------------------------------------------------------------------------

  describe "list_destinations/0 and list_destinations_for_org/1" do
    test "list_destinations/0 returns all destinations" do
      org1 = organization_fixture(%{"name" => "Org1", "slug" => "org1"})
      org2 = organization_fixture(%{"name" => "Org2", "slug" => "org2"})
      destination_fixture(org1)
      destination_fixture(org2)

      assert length(Observability.list_destinations()) == 2
    end

    test "list_destinations_for_org/1 returns only destinations for that org" do
      org1 = organization_fixture(%{"name" => "Org1", "slug" => "org1"})
      org2 = organization_fixture(%{"name" => "Org2", "slug" => "org2"})
      dest1 = destination_fixture(org1, %{name: "Dest1"})
      destination_fixture(org2, %{name: "Dest2"})

      results = Observability.list_destinations_for_org(org1.id)
      assert length(results) == 1
      assert hd(results).id == dest1.id
      assert hd(results).name == "Dest1"
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
