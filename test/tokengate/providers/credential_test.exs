defmodule Tokengate.Providers.CredentialTest do
  @moduledoc """
  A credential's fields split in two trust levels: `name`/`api_key_encrypted`
  are the operator-editable surface (cast from form params) while
  `provider_id`, `status` and the `error_*` bookkeeping are lifecycle state
  assigned explicitly by server code. These are changeset tests — no database.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Providers.Credential

  defp new_id, do: Ecto.UUID.generate()

  defp persisted(attrs \\ []) do
    struct(
      %Credential{
        id: new_id(),
        provider_id: new_id(),
        name: "Producción",
        api_key_encrypted: "sk-test-abcd",
        status: "active"
      },
      attrs
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  describe "create_changeset/2" do
    test "casts the operator fields, takes the provider explicitly and defaults status" do
      provider_id = new_id()

      changeset =
        Credential.create_changeset(%Credential{}, %{
          provider_id: provider_id,
          name: "Producción",
          api_key_encrypted: "sk-test-abcd"
        })

      assert changeset.valid?
      assert changeset.changes.name == "Producción"
      assert changeset.changes.api_key_encrypted == "sk-test-abcd"

      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.provider_id == provider_id
      assert applied.status == "active"
    end

    test "requires a provider and a secret" do
      changeset = Credential.create_changeset(%Credential{}, %{name: "Sin secretos"})

      refute changeset.valid?

      assert %{provider_id: ["can't be blank"], api_key_encrypted: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "accepts the provider in form shape (string key), always server-set" do
      provider_id = new_id()

      changeset =
        Credential.create_changeset(%Credential{}, %{
          "provider_id" => provider_id,
          "api_key_encrypted" => "sk-test-abcd"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :provider_id) == provider_id
    end

    test "a provider already set on the struct wins over the submitted one" do
      provider_id = new_id()

      changeset =
        Credential.create_changeset(
          %Credential{provider_id: provider_id},
          %{"provider_id" => new_id(), "api_key_encrypted" => "sk-test-abcd"}
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :provider_id) == provider_id
    end

    test "rejects a status outside the vocabulary" do
      changeset =
        Credential.create_changeset(%Credential{}, %{
          provider_id: new_id(),
          api_key_encrypted: "sk-test-abcd",
          status: "banned"
        })

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "a status forged through string-keyed params never reaches the row" do
      changeset =
        Credential.create_changeset(%Credential{}, %{
          "provider_id" => new_id(),
          "api_key_encrypted" => "sk-test-abcd",
          "status" => "error",
          "error_reason" => "unauthorized"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == "active"
      assert Ecto.Changeset.get_field(changeset, :error_reason) == nil
    end
  end

  describe "update_changeset/2" do
    test "casts the operator fields from form params" do
      changeset =
        persisted()
        |> Credential.update_changeset(%{
          "name" => "Staging",
          "api_key_encrypted" => "sk-new-1234"
        })

      assert changeset.valid?
      assert changeset.changes == %{name: "Staging", api_key_encrypted: "sk-new-1234"}
    end

    # The edit modal submits string-keyed params. None of the lifecycle fields
    # may move from there: a forged `credential[status]` would reactivate a key
    # the gateway disabled, and a forged `provider_id` would hand another
    # provider's lanes this secret.
    test "ignores provider_id, status and error bookkeeping coming from form params" do
      credential = persisted()

      changeset =
        Credential.update_changeset(credential, %{
          "provider_id" => new_id(),
          "status" => "error",
          "error_reason" => "unauthorized",
          "error_message" => "401 from upstream",
          "error_at" => "2026-11-17T10:00:00Z"
        })

      assert changeset.valid?
      assert changeset.changes == %{}
      assert Ecto.Changeset.get_field(changeset, :provider_id) == credential.provider_id
      assert Ecto.Changeset.get_field(changeset, :status) == "active"
    end

    test "never re-parents a credential, not even from programmatic attrs" do
      credential = persisted()

      changeset = Credential.update_changeset(credential, %{provider_id: new_id()})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :provider_id)
      assert Ecto.Changeset.get_field(changeset, :provider_id) == credential.provider_id
    end

    # The gateway disables a key after a 401/402/403 by calling
    # `Providers.update_credential/2` with atom-keyed attrs; the admin
    # reactivation clears them the same way.
    test "applies lifecycle state set programmatically with atom keys" do
      error_at = ~U[2026-11-17 10:00:00Z]

      changeset =
        persisted()
        |> Credential.update_changeset(%{
          status: "error",
          error_reason: "unauthorized",
          error_message: "401 from upstream",
          error_at: error_at
        })

      assert changeset.valid?

      assert changeset.changes == %{
               status: "error",
               error_reason: "unauthorized",
               error_message: "401 from upstream",
               error_at: error_at
             }
    end

    test "reactivation clears the error bookkeeping with explicit nils" do
      credential =
        persisted(
          status: "error",
          error_reason: "unauthorized",
          error_message: "401 from upstream",
          error_at: ~U[2026-11-17 10:00:00Z]
        )

      changeset =
        Credential.update_changeset(credential, %{
          status: "active",
          error_reason: nil,
          error_message: nil,
          error_at: nil
        })

      assert changeset.valid?

      assert changeset.changes == %{
               status: "active",
               error_reason: nil,
               error_message: nil,
               error_at: nil
             }
    end

    test "rejects a programmatic status outside the vocabulary" do
      changeset = Credential.update_changeset(persisted(), %{status: "banned"})

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "keeps the stored secret when the edit submits no new one" do
      credential = persisted()

      changeset = Credential.update_changeset(credential, %{"name" => "Staging"})

      assert changeset.valid?
      assert changeset.changes == %{name: "Staging"}
      assert Ecto.Changeset.get_field(changeset, :api_key_encrypted) == "sk-test-abcd"
    end
  end
end
