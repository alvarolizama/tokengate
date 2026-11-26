defmodule Tokengate.SmartRouter.ModelAliasTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Providers
  alias Tokengate.Providers.Model
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.{UseCase, UseCaseModel}

  defp model_fixture(name \\ nil) do
    {:ok, model} =
      Providers.create_model(%{
        "name" => name || "alias-test-#{System.unique_integer([:positive])}",
        "context_window" => 128_000,
        "model_type" => "llm"
      })

    model
  end

  defp use_case_fixture do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(%{key: "case_#{System.unique_integer([:positive])}", name: "Caso"})
      |> Repo.insert()

    use_case
  end

  defp binding_fixture(use_case, model) do
    {:ok, binding} =
      %UseCaseModel{}
      |> UseCaseModel.changeset(%{router_use_case_id: use_case.id, target_model_id: model.id})
      |> Repo.insert()

    binding
  end

  describe "the reserved \"router\" alias" do
    test "reserved_name?/1 is case-insensitive and trims" do
      for name <- ["router", "ROUTER", "Router", " Router ", "\trouter\n"] do
        assert Model.reserved_name?(name), "expected #{inspect(name)} to be reserved"
      end

      for name <- ["router-mini", "my-router", "routers", "auto", "", nil, 42] do
        refute Model.reserved_name?(name), "expected #{inspect(name)} not to be reserved"
      end
    end

    test "changeset/2 rejects every casing of the alias" do
      for name <- ["router", "ROUTER", " Router "] do
        changeset = Model.changeset(%Model{}, %{name: name, context_window: 128_000})

        refute changeset.valid?, "expected #{inspect(name)} to be rejected"

        assert [message] = errors_on(changeset).name
        assert message =~ "reserved by the gateway"
      end
    end

    test "names that merely contain \"router\" are still valid models" do
      for name <- ["router-mini", "my-router", "openrouter/auto"] do
        assert Model.changeset(%Model{}, %{name: name, context_window: 128_000}).valid?,
               "expected #{inspect(name)} to be accepted"
      end
    end

    test "create_model/1 surfaces the error instead of inserting the alias" do
      assert {:error, changeset} =
               Providers.create_model(%{"name" => "router", "context_window" => 1_000})

      assert %{name: [message]} = errors_on(changeset)
      assert message =~ "reserved by the gateway"
      assert Providers.get_model_by_name("router") == nil
    end
  end

  describe "Providers.delete_model/1 and use-case bindings" do
    test "returns {:error, changeset} (not Ecto.ConstraintError) when a use case still binds the model" do
      model = model_fixture()
      use_case = use_case_fixture()
      binding = binding_fixture(use_case, model)

      assert {:error, changeset} = Providers.delete_model(model)

      assert %{id: [message]} = errors_on(changeset)
      assert message == "the model is still assigned to a SmartRouter use case"

      # Nothing was deleted: the model and the binding are still there.
      assert Repo.get(Model, model.id)
      assert Repo.get(UseCaseModel, binding.id)
    end

    test "deletes the model once no use case binds it, and keeps log rows" do
      model = model_fixture()
      use_case = use_case_fixture()
      _binding = binding_fixture(use_case, model)

      # The binding is what blocks the delete; other router pointers nilify.
      {:ok, _use_case} =
        use_case
        |> Ecto.Changeset.change(%{fallback_model_id: model.id})
        |> Repo.update()

      assert {:error, _changeset} = Providers.delete_model(model)

      # Unbind the use case, then the delete goes through even though the use
      # case still points its fallback at the model (ON DELETE NILIFY ALL).
      from_binding = Repo.get_by!(UseCaseModel, router_use_case_id: use_case.id)
      {:ok, _} = Repo.delete(from_binding)

      assert {:ok, _model} = Providers.delete_model(model)
      assert Repo.get(Model, model.id) == nil

      assert Repo.get!(UseCase, use_case.id).fallback_model_id == nil
    end

    test "request_logs.model_id survives the model deletion (no FK)" do
      model = model_fixture()

      {:ok, group} = Accounts.create_group(%{"name" => "G #{System.unique_integer([:positive])}"})

      {:ok, user} =
        Accounts.register_user(%{
          "email" => "log-#{System.unique_integer([:positive])}@example.com",
          "name" => "Log User",
          "password" => "ValidPassword123"
        })

      {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

      assert {:ok, log} =
               Logs.log_request(%{
                 subject_type: "user",
                 group_member_id: member.id,
                 model_id: model.id,
                 model_requested: "alias-test",
                 status_code: 200
               })

      assert {:ok, _model} = Providers.delete_model(model)

      reloaded = Repo.get_by!(Tokengate.Logs.RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded.model_id == model.id
    end
  end
end
