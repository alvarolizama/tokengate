defmodule Tokengate.Accounts.ServiceTest do
  use Tokengate.DataCase, async: true

  import Ecto.Query

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{Service, ServiceSupervisor}

  defp unique, do: System.unique_integer([:positive])

  describe "services name uniqueness" do
    test "creating two services with the same name returns a field error, not a crash" do
      name = "svc-dup-#{unique()}"

      assert {:ok, service} = Accounts.create_service(%{name: name})
      assert service.name == name

      # El índice único `services_name_unique` es el que respalda el
      # `unique_constraint(:name)` del changeset: sin él, el segundo insert
      # levantaría Ecto.ConstraintError (500) en vez de un error de campo.
      assert {:error, changeset} = Accounts.create_service(%{name: name})

      refute changeset.valid?
      assert {"has already been taken", _} = changeset.errors[:name]
      assert Repo.aggregate(from(s in Service, where: s.name == ^name), :count) == 1
    end

    test "renaming a service onto an existing name is refused" do
      name_a = "svc-a-#{unique()}"
      name_b = "svc-b-#{unique()}"

      assert {:ok, _a} = Accounts.create_service(%{name: name_a})
      assert {:ok, b} = Accounts.create_service(%{name: name_b})

      assert {:error, changeset} = Accounts.update_service(b, %{name: name_a})
      assert {"has already been taken", _} = changeset.errors[:name]

      # La fila sigue con su nombre original.
      assert Accounts.get_service(b.id).name == name_b
    end
  end

  describe "service supervisors" do
    test "a supervisor with a service that does not exist is a changeset error" do
      {:ok, user} = Accounts.register_user(unique_user_attrs())

      changeset =
        ServiceSupervisor.changeset(%ServiceSupervisor{}, %{
          service_id: Ecto.UUID.generate(),
          user_id: user.id
        })

      # La FK existe en la DB: declararla evita que un id inválido reviente
      # como Ecto.ConstraintError y lo convierte en un error de campo. El cast
      # del UUID es válido, así que el changeset sólo falla al tocar la DB.
      assert {:error, changeset} = Repo.insert(changeset)
      assert {"does not exist", _} = changeset.errors[:service_id]
    end

    test "a supervisor with a user that does not exist is a changeset error" do
      assert {:ok, service} = Accounts.create_service(%{name: "svc-sup-#{unique()}"})

      changeset =
        ServiceSupervisor.changeset(%ServiceSupervisor{}, %{
          service_id: service.id,
          user_id: Ecto.UUID.generate()
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert {"does not exist", _} = changeset.errors[:user_id]
    end

    test "a supervisor with a real service and user is inserted" do
      assert {:ok, service} = Accounts.create_service(%{name: "svc-ok-#{unique()}"})
      {:ok, user} = Accounts.register_user(unique_user_attrs())

      assert {:ok, supervisor} =
               %ServiceSupervisor{}
               |> ServiceSupervisor.changeset(%{service_id: service.id, user_id: user.id})
               |> Repo.insert()

      assert supervisor.service_id == service.id
      assert supervisor.user_id == user.id
    end
  end

  defp unique_user_attrs do
    u = unique()

    %{
      email: "service-sup-#{u}@example.com",
      name: "Service Sup #{u}",
      password: "password-secret-#{u}1"
    }
  end
end
