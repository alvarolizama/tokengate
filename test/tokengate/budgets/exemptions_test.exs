defmodule Tokengate.Budgets.ExemptionsTest do
  @moduledoc """
  Tests for the budget exemptions context and schema: CRUD, uniqueness per
  (scope, subject), subject validation, and the `exempt?/3` hot-path lookup
  including group inheritance. Only the `global_daily` scope exists.
  """

  use Tokengate.DataCase, async: false
  alias Tokengate.Accounts
  alias Tokengate.Budgets.Exemption
  alias Tokengate.Budgets.Exemptions

  defp unique, do: System.unique_integer([:positive])

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "exempt-user-#{unique()}@example.com",
        "name" => "Exempt User",
        "password" => "ValidPassword123"
      })

    user
  end

  defp group_fixture do
    {:ok, group} = Accounts.create_group(%{"name" => "Exempt Group #{unique()}"})
    group
  end

  defp service_fixture do
    {:ok, group} = Accounts.create_group(%{name: "Exempt Group #{unique()}"})

    {:ok, service} =
      Accounts.create_service(%{
        "name" => "Exempt Service #{unique()}",
        "group_id" => group.id,
        "concurrency_limit" => 5,
        "rpm_limit" => 60
      })

    service
  end

  describe "changeset validation" do
    test "requires exactly one subject matching subject_type" do
      user = user_fixture()

      changeset =
        Exemption.changeset(%Exemption{}, %{
          "scope" => "global_daily",
          "subject_type" => "user",
          "user_id" => user.id
        })

      assert changeset.valid?
    end

    test "rejects missing subject id" do
      changeset =
        Exemption.changeset(%Exemption{}, %{
          "scope" => "global_daily",
          "subject_type" => "user"
        })

      refute changeset.valid?
      assert "is required for this subject type" in errors_on(changeset).user_id
    end

    test "rejects multiple subjects" do
      user = user_fixture()
      group = group_fixture()

      changeset =
        Exemption.changeset(%Exemption{}, %{
          "scope" => "global_daily",
          "subject_type" => "user",
          "user_id" => user.id,
          "group_id" => group.id
        })

      refute changeset.valid?
      assert "only one subject per exemption" in errors_on(changeset).subject_type
    end

    test "rejects unknown scope and subject_type" do
      user = user_fixture()

      changeset =
        Exemption.changeset(%Exemption{}, %{
          "scope" => "weekly",
          "subject_type" => "user",
          "user_id" => user.id
        })

      refute changeset.valid?
    end

    test "rejects the removed user_daily scope" do
      user = user_fixture()

      changeset =
        Exemption.changeset(%Exemption{}, %{
          "scope" => "user_daily",
          "subject_type" => "user",
          "user_id" => user.id
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).scope
    end
  end

  describe "add/remove/list" do
    test "adds and lists an exemption with subject preloaded" do
      user = user_fixture()

      assert {:ok, exemption} =
               Exemptions.add(%{
                 "scope" => "global_daily",
                 "subject_type" => "user",
                 "user_id" => user.id
               })

      assert [listed] = Exemptions.list_for_scope("global_daily")
      assert listed.id == exemption.id
      assert Exemptions.subject_label(listed) =~ user.email
    end

    test "rejects duplicate (scope, subject)" do
      user = user_fixture()

      attrs = %{
        "scope" => "global_daily",
        "subject_type" => "user",
        "user_id" => user.id
      }

      assert {:ok, _} = Exemptions.add(attrs)
      assert {:error, %Ecto.Changeset{}} = Exemptions.add(attrs)
    end

    test "removes by id" do
      user = user_fixture()

      {:ok, exemption} =
        Exemptions.add(%{
          "scope" => "global_daily",
          "subject_type" => "user",
          "user_id" => user.id
        })

      assert {1, nil} = Exemptions.remove(exemption.id)
      assert Exemptions.list_for_scope("global_daily") == []
    end
  end

  describe "exempt?/3" do
    test "user exemption matches by user id" do
      user = user_fixture()

      Exemptions.add(%{"scope" => "global_daily", "subject_type" => "user", "user_id" => user.id})

      assert Exemptions.exempt?("global_daily", %{type: "user", id: user.id}, nil)
      # A different user is not exempt.
      refute Exemptions.exempt?("global_daily", %{type: "user", id: Ecto.UUID.generate()}, nil)
    end

    test "group exemption applies to group members via group subject" do
      user = user_fixture()
      group = group_fixture()

      Exemptions.add(%{
        "scope" => "global_daily",
        "subject_type" => "group",
        "group_id" => group.id
      })

      member_subject = %{type: "user", id: user.id}

      assert Exemptions.exempt?("global_daily", member_subject, %{type: "group", id: group.id})

      refute Exemptions.exempt?("global_daily", member_subject, %{
               type: "group",
               id: Ecto.UUID.generate()
             })
    end

    test "service exemption matches by service id" do
      service = service_fixture()

      Exemptions.add(%{
        "scope" => "global_daily",
        "subject_type" => "service",
        "service_id" => service.id
      })

      assert Exemptions.exempt?("global_daily", %{type: "service", id: service.id}, nil)
    end

    test "unknown subject type is never exempt" do
      refute Exemptions.exempt?("global_daily", %{type: "robot", id: "x"}, nil)
    end
  end
end
