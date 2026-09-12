defmodule Tokengate.ObservabilityTest do
  use Tokengate.DataCase, async: true
  alias Tokengate.Accounts
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp group_fixture do
    {:ok, group} =
      Accounts.create_group(%{
        "name" => "Platform Group",
        "monthly_budget_per_user_usd" => "100.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      })

    group
  end

  defp valid_destination_attrs(attrs \\ %{}) do
    group = group_fixture()

    Map.merge(
      %{
        name: "Honeycomb",
        type: "otlp_webhook",
        url: "https://api.honeycomb.io",
        headers: %{"X-Api-Key" => "secret"},
        group_id: group.id
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
      assert dest.group_id == attrs.group_id
    end

    test "applies default type when type omitted" do
      group = group_fixture()

      {:ok, dest} =
        Observability.create_destination(%{
          name: "Default Dest",
          type: "otlp_webhook",
          group_id: group.id
        })

      assert dest.type == "otlp_webhook"
    end

    test "validates type inclusion" do
      group = group_fixture()

      {:error, changeset} =
        Observability.create_destination(%{
          name: "Bad",
          type: "invalid_type",
          group_id: group.id
        })

      assert "is invalid" in errors_on(changeset).type
    end

    test "requires name, group_id" do
      {:error, changeset} = Observability.create_destination(%{})

      assert errors_on(changeset).name
      assert errors_on(changeset).group_id
    end
  end

  # ---------------------------------------------------------------------------
  # list_destinations
  # ---------------------------------------------------------------------------

  describe "list_destinations/1" do
    test "returns destinations scoped to the given group" do
      dest1 = destination_fixture(%{name: "Dest1"})
      destination_fixture(%{name: "Dest2"})

      results = Observability.list_destinations(dest1.group_id)

      assert length(results) == 1
      assert hd(results).name == "Dest1"
    end

    test "returns all destinations for a group" do
      group = group_fixture()

      destination_fixture(%{name: "Dest1", group_id: group.id})
      destination_fixture(%{name: "Dest2", group_id: group.id})

      assert length(Observability.list_destinations(group.id)) == 2
    end

    test "returns empty list when no destinations for group" do
      group = group_fixture()

      assert Observability.list_destinations(group.id) == []
    end

    test "does not return destinations from other groups" do
      dest1 = destination_fixture(%{name: "Dest1"})
      dest2 = destination_fixture(%{name: "Dest2"})

      refute dest1.group_id == dest2.group_id

      assert length(Observability.list_destinations(dest1.group_id)) == 1
      assert length(Observability.list_destinations(dest2.group_id)) == 1
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

      assert Observability.list_destinations(dest.group_id) == []
    end
  end
end
