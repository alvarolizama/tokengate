defmodule Tokengate.AccountsTest do
  use Tokengate.DataCase, async: true
  alias Tokengate.Accounts
  alias Tokengate.Accounts.{ApiKey, Service, ServiceSupervisor, Group, GroupMember, User}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_group_attrs(attrs) do
    Map.merge(
      %{
        "name" => "Platform Group",
        "monthly_budget_per_user_usd" => "100.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      },
      attrs
    )
  end

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} = Accounts.create_group(valid_group_attrs(attrs))
    group
  end

  defp valid_user_attrs(attrs) do
    Map.merge(
      %{
        "email" => "user#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      },
      attrs
    )
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} = Accounts.register_user(valid_user_attrs(attrs))
    user
  end

  defp valid_group_member_attrs(user, group, attrs \\ %{}) do
    Map.merge(
      %{
        "user_id" => user.id,
        "group_id" => group.id
      },
      attrs
    )
  end

  defp valid_service_attrs(attrs) do
    Map.merge(
      %{
        "name" => "Service #{System.unique_integer([:positive])}",
        "concurrency_limit" => 5,
        "rpm_limit" => 60
      },
      attrs
    )
  end

  defp service_fixture(attrs \\ %{}) do
    {:ok, service} = Accounts.create_service(valid_service_attrs(attrs))
    service
  end

  # ---------------------------------------------------------------------------
  # Group changesets
  # ---------------------------------------------------------------------------

  describe "group changesets" do
    test "create_group/1 with valid attrs succeeds and applies defaults when omitted" do
      attrs =
        valid_group_attrs(%{"default_concurrency_limit" => nil, "default_rpm_limit" => nil})

      # remove from attrs to test DB default
      attrs = Map.delete(attrs, "default_concurrency_limit") |> Map.delete("default_rpm_limit")

      assert {:ok, %Group{} = group} = Accounts.create_group(attrs)
      assert group.name == "Platform Group"
      assert group.default_concurrency_limit == 5
      assert group.default_rpm_limit == 60
    end

    test "create_group/1 requires name" do
      {:error, changeset} = Accounts.create_group(%{})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "create_group/1 validates concurrency/rpm greater than 0" do
      attrs = valid_group_attrs(%{"default_concurrency_limit" => 0, "default_rpm_limit" => 0})
      {:error, changeset} = Accounts.create_group(attrs)

      assert "must be greater than 0" in errors_on(changeset).default_concurrency_limit
      assert "must be greater than 0" in errors_on(changeset).default_rpm_limit
    end

    test "create_group/1 allows nil budget" do
      attrs = valid_group_attrs(%{"monthly_budget_per_user_usd" => nil})

      assert {:ok, %Group{} = group} = Accounts.create_group(attrs)
      assert group.name =~ "Group"
    end
  end

  describe "delete_group/1" do
    test "deletes a group with no members" do
      group = group_fixture()

      assert {:ok, _} = Accounts.delete_group(group)
      assert Accounts.get_group(group.id) == nil
    end

    test "deletes a group and cascades cleanup of members, api keys, and extra models" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      assert {:ok, _} = Accounts.delete_group(group)
      assert Accounts.get_group(group.id) == nil
      assert Accounts.get_group_member(tm.id) == nil
    end

    test "deletes a group with multiple members" do
      group = group_fixture()
      user1 = user_fixture()
      user2 = user_fixture(%{"email" => "user2#{System.unique_integer([:positive])}@example.com"})

      {:ok, tm1} = Accounts.create_group_member(valid_group_member_attrs(user1, group))
      {:ok, tm2} = Accounts.create_group_member(valid_group_member_attrs(user2, group))

      assert {:ok, _} = Accounts.delete_group(group)
      assert Accounts.get_group(group.id) == nil
      assert Accounts.get_group_member(tm1.id) == nil
      assert Accounts.get_group_member(tm2.id) == nil
    end

    test "deletes a group that still has a legacy services.group_id reference" do
      # Regression: `services.group_id` is a legacy column (no longer on the
      # Service schema) whose FK is ON DELETE RESTRICT. Deleting a group used
      # to raise Ecto.ConstraintError because delete_group/1 never cleared it.
      group = group_fixture()
      service = service_fixture()

      Tokengate.Repo.update_all(
        from(s in "services", where: s.id == type(^service.id, :binary_id)),
        set: [group_id: Ecto.UUID.dump!(group.id)]
      )

      assert {:ok, _} = Accounts.delete_group(group)
      assert Accounts.get_group(group.id) == nil

      # The service survives, detached from the deleted group.
      assert Accounts.get_service(service.id)

      assert Tokengate.Repo.one(
               from(s in "services",
                 where: s.id == type(^service.id, :binary_id),
                 select: s.group_id
               )
             ) == nil
    end

    # Los destinos de observabilidad dejaron de colgar de la sub: borrar un
    # grupo ya no toca los webhooks (son globales).
    test "deleting a group leaves the observability destinations alone" do
      group = group_fixture()
      name = "Dest #{System.unique_integer([:positive])}"

      {:ok, dest} =
        Tokengate.Observability.create_destination(%{
          "name" => name,
          "type" => "otlp_webhook",
          "url" => "https://example.com/otlp"
        })

      assert {:ok, _} = Accounts.delete_group(group)
      assert Accounts.get_group(group.id) == nil
      assert Tokengate.Observability.get_destination(dest.id)
    end
  end

  # ---------------------------------------------------------------------------
  # User registration / auth
  # ---------------------------------------------------------------------------

  describe "user registration" do
    test "register_user/1 hashes the password and does not store plaintext" do
      attrs = valid_user_attrs(%{"password" => "ValidPassword123"})
      assert {:ok, %User{} = user} = Accounts.register_user(attrs)
      assert user.password_hash
      assert user.password_hash != "ValidPassword123"
      assert user.global_role == "user"
      # virtual password not persisted (still set on struct for convenience)
      assert user.password == "ValidPassword123"
    end

    test "register_user/1 lowercases email" do
      attrs = valid_user_attrs(%{"email" => "MixedCase@Example.COM"})
      assert {:ok, %User{} = user} = Accounts.register_user(attrs)
      assert user.email == "mixedcase@example.com"
    end

    test "register_user/1 requires a valid email format" do
      attrs = valid_user_attrs(%{"email" => "not-an-email"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "must be a valid email address" in errors_on(changeset).email
    end

    test "register_user/1 enforces password min 12 chars" do
      attrs = valid_user_attrs(%{"password" => "Short1"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "register_user/1 enforces password has a digit and a letter" do
      no_digit = valid_user_attrs(%{"password" => "NoDigitsPassword"})
      {:error, cs_digit} = Accounts.register_user(no_digit)
      assert "must contain a digit" in errors_on(cs_digit).password

      no_letter = valid_user_attrs(%{"password" => "123456789012"})
      {:error, cs_letter} = Accounts.register_user(no_letter)
      assert "must contain a letter" in errors_on(cs_letter).password
    end

    test "register_user/1 enforces unique email" do
      user_fixture(%{"email" => "dup@example.com"})
      attrs = valid_user_attrs(%{"email" => "DUP@example.com"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "authenticate_user/2" do
    test "succeeds with correct credentials" do
      user_fixture(%{"email" => "auth@example.com", "password" => "ValidPassword123"})

      assert {:ok, %User{email: "auth@example.com"}} =
               Accounts.authenticate_user("auth@example.com", "ValidPassword123")
    end

    test "succeeds with mixed-case email input" do
      user_fixture(%{"email" => "auth@example.com", "password" => "ValidPassword123"})
      assert {:ok, _user} = Accounts.authenticate_user("AUTH@example.com", "ValidPassword123")
    end

    test "fails with wrong password" do
      user_fixture(%{"email" => "auth2@example.com", "password" => "ValidPassword123"})

      assert {:error, :unauthorized} =
               Accounts.authenticate_user("auth2@example.com", "WrongPassword456")
    end

    test "fails with unknown email (timing-safe nil)" do
      # Should not raise; should return error and call no_user_verify internally.
      assert {:error, :unauthorized} =
               Accounts.authenticate_user("nonexistent@example.com", "AnyPassword123")
    end
  end

  # ---------------------------------------------------------------------------
  # User changes own password
  # ---------------------------------------------------------------------------

  describe "update_user_password/2" do
    test "changes the password with the correct current password" do
      user = user_fixture(%{"password" => "OldPassword123"})

      assert {:ok, %User{}} =
               Accounts.update_user_password(user, %{
                 "current_password" => "OldPassword123",
                 "password" => "NewPassword456"
               })

      assert {:ok, _} = Accounts.authenticate_user(user.email, "NewPassword456")
      assert {:error, :unauthorized} = Accounts.authenticate_user(user.email, "OldPassword123")
    end

    test "rejects a wrong current password" do
      user = user_fixture(%{"password" => "OldPassword123"})

      assert {:error, changeset} =
               Accounts.update_user_password(user, %{
                 "current_password" => "WrongPassword789",
                 "password" => "NewPassword456"
               })

      assert "no es correcta" in errors_on(changeset).current_password
    end

    test "validates the complexity of the new password" do
      user = user_fixture(%{"password" => "OldPassword123"})

      assert {:error, changeset} =
               Accounts.update_user_password(user, %{
                 "current_password" => "OldPassword123",
                 "password" => "short1"
               })

      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end
  end

  # ---------------------------------------------------------------------------
  # Group member + API key creation (atomic)
  # ---------------------------------------------------------------------------

  describe "create_group_member/1" do
    test "creates a group member and provisions an API key atomically, returns token once" do
      group = group_fixture()
      user = user_fixture()

      attrs = valid_group_member_attrs(user, group)

      assert {:ok, %GroupMember{} = tm} = Accounts.create_group_member(attrs)
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)
      assert is_binary(token)
      assert String.starts_with?(token, "tg-")

      # API key was created in the same transaction
      tm_loaded = Repo.preload(tm, [:api_key])
      assert %ApiKey{} = api_key = tm_loaded.api_key
      assert api_key.key_hash == Accounts.hash_api_key(token)
      assert api_key.key_prefix == String.slice(token, 0, 8)
      assert api_key.status == "active"
    end

    test "token is verifiable via get_group_member_by_api_key/1" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      assert {:ok, %GroupMember{}} = Accounts.get_group_member_by_api_key(token)
    end

    test "enforces unique (user_id, group_id)" do
      group = group_fixture()
      user = user_fixture()

      {:ok, _tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      assert {:error, changeset} =
               Accounts.create_group_member(valid_group_member_attrs(user, group))

      assert "has already been taken" in errors_on(changeset).group_id
    end

    test "validates status inclusion" do
      group = group_fixture()
      user = user_fixture()

      attrs =
        valid_group_member_attrs(user, group, %{
          "status" => "invalid"
        })

      assert {:error, changeset} = Accounts.create_group_member(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "does not store the plaintext token; only the hash" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)
      tm_loaded = Repo.preload(tm, [:api_key])

      refute tm_loaded.api_key.key_hash == token
      refute String.contains?(tm_loaded.api_key.key_hash, token)
    end
  end

  # ---------------------------------------------------------------------------
  # API key lookup / replace
  # ---------------------------------------------------------------------------

  describe "api key generation & lookup" do
    test "generate_api_key_material/0 produces tg- prefixed, base64url token" do
      {token, hash, prefix} = Accounts.generate_api_key_material()

      assert String.starts_with?(token, "tg-")
      assert byte_size(token) > 20
      assert String.length(prefix) == 8
      assert prefix == String.slice(token, 0, 8)
      # Hash is lowercase hex sha256
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
      assert hash == Accounts.hash_api_key(token)
    end

    test "get_group_member_by_api_key/1 preloads group and user" do
      group = group_fixture(%{"name" => "Lookup Group"})
      user = user_fixture(%{"name" => "Lookup User", "email" => "lookup@example.com"})

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      assert {:ok, %GroupMember{group: %Group{}, user: %User{}}} =
               Accounts.get_group_member_by_api_key(token)

      {:ok, tm} = Accounts.get_group_member_by_api_key(token)
      assert tm.group.name == "Lookup Group"
      assert tm.user.email == "lookup@example.com"
    end

    test "get_group_member_by_api_key/1 returns not_found for revoked key" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      # Revoke the api key directly
      tm_loaded = Repo.preload(tm, [:api_key])
      {:ok, _} = Accounts.revoke_api_key(tm_loaded.api_key)

      assert {:error, :not_found} = Accounts.get_group_member_by_api_key(token)
    end

    test "get_group_member_by_api_key/1 returns not_found for garbage token" do
      assert {:error, :not_found} = Accounts.get_group_member_by_api_key("tg-garbage")
    end

    test "allows multiple active keys for the same group_member (no per-subject unique index)" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _api_key, _token} = Accounts.replace_api_key(tm)
      tm_loaded = Repo.preload(tm, [:api_key])

      # Ya no hay índice único por sujeto: una segunda key activa del mismo
      # miembro convive con la primera (el error de unicidad ya no existe).
      {:ok, second_key} =
        Accounts.create_api_key(%{
          "group_member_id" => tm_loaded.id,
          "key_hash" => Accounts.hash_api_key("tg-somethingelse"),
          "key_prefix" => "tg-somet",
          "label" => "segunda key"
        })

      assert second_key.status == "active"
      assert second_key.group_member_id == tm_loaded.id
      assert second_key.label == "segunda key"

      # Ambas keys activas existen para el mismo group_member_id.
      keys =
        from(k in ApiKey,
          where: k.group_member_id == ^tm_loaded.id and k.status == "active",
          select: count(k.id)
        )
        |> Repo.one()

      assert keys == 2
    end
  end

  describe "replace_api_key/1" do
    test "revokes the old key and issues a new one, returning new token" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))
      {:ok, _old_key, old_token} = Accounts.replace_api_key(tm)

      assert {:ok, %ApiKey{} = new_key, new_token} = Accounts.replace_api_key(tm)
      assert new_token != old_token
      assert String.starts_with?(new_token, "tg-")
      assert new_key.status == "active"
      assert new_key.key_hash == Accounts.hash_api_key(new_token)

      # Old token no longer resolves to an active key
      assert {:error, :not_found} = Accounts.get_group_member_by_api_key(old_token)
      # New token does
      assert {:ok, _} = Accounts.get_group_member_by_api_key(new_token)
    end

    test "old token is invalidated after replacement" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      {:ok, _new_key, _new_token} = Accounts.replace_api_key(tm)

      # There is still exactly one api_key row for this group_member
      tm_loaded = Repo.preload(tm, [:api_key])
      assert tm_loaded.api_key.status == "active"
      # The key hash has changed (no longer matches the old token)
      refute tm_loaded.api_key.key_hash == Accounts.hash_api_key("old")
    end
  end

  # ---------------------------------------------------------------------------
  # effective_limits/1
  # ---------------------------------------------------------------------------

  describe "effective_limits/1" do
    test "returns group defaults when the user has no own limits (propio || contenedor)" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      limits = Accounts.effective_limits(tm)

      assert limits.concurrency_limit == 10
      assert limits.rpm_limit == 120
    end

    test "the user's own concurrency wins over the group default (absolute, never added)" do
      group = group_fixture()
      user = user_fixture(%{"default_concurrency_limit" => 15})

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      # 15 — NO 15 + 10: el default del grupo es contenedor, no sumando.
      assert Accounts.effective_limits(tm).concurrency_limit == 15
    end

    test "the user's own rpm wins over the group default (absolute, never added)" do
      group = group_fixture()
      user = user_fixture(%{"default_rpm_limit" => 160})

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      # 160 — NO 160 + 120: el default del grupo es contenedor, no sumando.
      assert Accounts.effective_limits(tm).rpm_limit == 160
      assert Accounts.effective_limits(tm).concurrency_limit == 10
    end

    test "a member without preloads resolves propio || contenedor (preloads :user)" do
      group = group_fixture()
      user = user_fixture(%{"default_rpm_limit" => 200})

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      # Sin precargar: la única regla tiene que traer dueño y contenedor.
      assert %Ecto.Association.NotLoaded{} = tm.user
      assert %Ecto.Association.NotLoaded{} = tm.group

      limits = Accounts.effective_limits(tm)

      assert limits.rpm_limit == 200
      assert limits.concurrency_limit == 10
    end

    test "editing the user's own limits moves the member's effective limits" do
      group = group_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_group_member(valid_group_member_attrs(user, group))

      assert Accounts.effective_limits(tm).concurrency_limit == 10
      assert Accounts.effective_limits(tm).rpm_limit == 120

      {:ok, _user} =
        Accounts.admin_update_user(user, %{
          "default_concurrency_limit" => 40,
          "default_rpm_limit" => 400
        })

      limits = Accounts.effective_limits(tm)

      assert limits.concurrency_limit == 40
      assert limits.rpm_limit == 400
    end

    test "a member without own limits or group default falls back to the module default" do
      # Contenedor sin defaults (fila construida a mano): el último eslabón.
      group = %Group{
        id: Ecto.UUID.generate(),
        default_concurrency_limit: nil,
        default_rpm_limit: nil
      }

      user = %User{id: Ecto.UUID.generate()}

      member = %GroupMember{id: Ecto.UUID.generate(), group: group, user: user}

      assert Accounts.effective_limits(member) == %{concurrency_limit: 5, rpm_limit: 60}
    end

    test "service virtual member uses the service's absolute limits" do
      # Service limits are absolute now (no group defaults underneath).
      service =
        service_fixture(%{
          "concurrency_limit" => 3,
          "rpm_limit" => 30
        })

      service = Repo.preload(service, [:api_key])
      member = TokengateWeb.Plugs.ApiAuth.service_to_virtual_member(service)

      # The virtual member must NOT crash effective_limits (was a nil.group crash)
      limits = Accounts.effective_limits(member)

      assert limits.concurrency_limit == 3
      assert limits.rpm_limit == 30
    end

    test "service virtual member without limits falls back to defaults" do
      service = service_fixture(%{"concurrency_limit" => nil, "rpm_limit" => nil})
      service = Repo.preload(service, [:api_key])
      member = TokengateWeb.Plugs.ApiAuth.service_to_virtual_member(service)

      limits = Accounts.effective_limits(member)

      assert limits.concurrency_limit == 5
      assert limits.rpm_limit == 60
    end

    test "service virtual member with no backing service returns safe defaults" do
      # Build a virtual member with a non-existent service id
      member = %GroupMember{
        id: Ecto.UUID.generate(),
        group_id: nil,
        user_id: nil,
        status: "active",
        group: nil,
        user: nil,
        api_key: nil
      }

      limits = Accounts.effective_limits(member)

      assert limits.concurrency_limit == 5
      assert limits.rpm_limit == 60
    end
  end

  # ---------------------------------------------------------------------------
  # Service supervisors
  # ---------------------------------------------------------------------------

  describe "service supervisors" do
    test "add_service_supervisor/2 + services_for_supervisor/1 returns the service" do
      service = service_fixture(%{"name" => "Alpha"})
      user = user_fixture()

      assert {:ok, %ServiceSupervisor{} = supervisor} =
               Accounts.add_service_supervisor(service.id, user.id)

      assert supervisor.service_id == service.id
      assert supervisor.user_id == user.id

      services = Accounts.services_for_supervisor(user.id)
      assert [%Service{id: id}] = services
      assert id == service.id
    end

    test "services_for_supervisor/1 orders by name" do
      user = user_fixture()

      later = service_fixture(%{"name" => "Zeta"})
      earlier = service_fixture(%{"name" => "Alpha"})

      {:ok, _} = Accounts.add_service_supervisor(later.id, user.id)
      {:ok, _} = Accounts.add_service_supervisor(earlier.id, user.id)

      services = Accounts.services_for_supervisor(user.id)
      assert Enum.map(services, & &1.name) == ["Alpha", "Zeta"]
    end

    test "services_for_supervisor/1 preloads :api_key" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

      [%Service{} = s] = Accounts.services_for_supervisor(user.id)
      # After `preload: [:api_key]`, the field is either a real %ServiceApiKey{}
      # or `nil` (has_one with no result). Critically, the field is NOT left
      # as %Ecto.Association.NotLoaded{} — that would prove preload was missed.
      refute match?(%Ecto.Association.NotLoaded{}, s.api_key)
    end

    test "add_service_supervisor/2 is idempotent — second add returns the existing row" do
      service = service_fixture()
      user = user_fixture()

      assert {:ok, first} = Accounts.add_service_supervisor(service.id, user.id)
      assert {:ok, second} = Accounts.add_service_supervisor(service.id, user.id)
      assert first.id == second.id
      # Only one row exists
      assert length(Accounts.service_supervisor_ids(service.id)) == 1
    end

    test "remove_service_supervisor/2 + services_for_supervisor/1 returns empty" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      assert length(Accounts.services_for_supervisor(user.id)) == 1

      assert {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)
      assert Accounts.services_for_supervisor(user.id) == []
      assert Accounts.service_supervisor_ids(service.id) == []
    end

    test "remove_service_supervisor/2 is idempotent — second remove is :not_found" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

      assert {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)
      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
      # Calling again still does not error
      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
    end

    test "remove_service_supervisor/2 on never-added pair returns :not_found" do
      service = service_fixture()
      user = user_fixture()

      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
    end

    # The supervision row is the ONLY thing that grants the read-only
    # supervised area, so its presence/absence is the access check.
    test "supervises_service?/2 mirrors the row" do
      service = service_fixture()
      other = service_fixture()
      user = user_fixture()

      refute Accounts.supervises_service?(user.id, service.id)

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      assert Accounts.supervises_service?(user.id, service.id)
      refute Accounts.supervises_service?(user.id, other.id)

      {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)
      refute Accounts.supervises_service?(user.id, service.id)
    end

    test "supervises_service?/2 is false for nil args instead of raising" do
      service = service_fixture()

      refute Accounts.supervises_service?(nil, service.id)
      refute Accounts.supervises_service?("some-user", nil)
      refute Accounts.supervises_service?(nil, nil)
    end

    test "add_service_supervisor/2 broadcasts {:supervisor_added, service_id}" do
      service = service_fixture()
      user = user_fixture()

      Phoenix.PubSub.subscribe(Tokengate.PubSub, Accounts.supervised_services_topic(user.id))

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

      assert_receive {:supervisor_added, service_id}
      assert service_id == service.id

      # Idempotent re-add (the row already exists) is not a new assignment,
      # so it does not wake anyone up.
      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      refute_receive {:supervisor_added, _}, 50
    end

    test "remove_service_supervisor/2 broadcasts {:supervisor_removed, service_id}" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Accounts.supervised_services_topic(user.id))

      {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

      assert_receive {:supervisor_removed, service_id}
      assert service_id == service.id

      # Removing a pair that is already gone changes nothing.
      {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
      refute_receive {:supervisor_removed, _}, 50
    end

    test "supervised_services_topic/1 is per user" do
      refute Accounts.supervised_services_topic("a") == Accounts.supervised_services_topic("b")
      assert Accounts.supervised_services_topic("a") == "supervised_services:a"
    end

    test "service_supervisor_ids/1 returns the supervising user ids" do
      service = service_fixture()
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user1.id)
      {:ok, _} = Accounts.add_service_supervisor(service.id, user2.id)

      ids = Accounts.service_supervisor_ids(service.id)
      assert length(ids) == 2
      assert user1.id in ids
      assert user2.id in ids
    end

    test "service_supervisor_ids/1 is empty for a service with no supervisors" do
      service = service_fixture()
      assert Accounts.service_supervisor_ids(service.id) == []
    end

    test "service_supervisors/1 returns structs with :user preloaded" do
      service = service_fixture()

      user1 =
        user_fixture(%{
          "name" => "Alpha User",
          "email" => "alpha#{System.unique_integer([:positive])}@example.com"
        })

      user2 =
        user_fixture(%{
          "name" => "Beta User",
          "email" => "beta#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _} = Accounts.add_service_supervisor(service.id, user1.id)
      {:ok, _} = Accounts.add_service_supervisor(service.id, user2.id)

      supervisors = Accounts.service_supervisors(service.id)
      assert length(supervisors) == 2

      for %ServiceSupervisor{user: %User{}} = ss <- supervisors do
        assert ss.service_id == service.id
        assert ss.user_id in [user1.id, user2.id]
      end

      user_ids = supervisors |> Enum.map(& &1.user_id) |> Enum.sort()
      assert user_ids == Enum.sort([user1.id, user2.id])
    end

    test "service_supervisors/1 is empty for a service with no supervisors" do
      service = service_fixture()
      assert Accounts.service_supervisors(service.id) == []
    end
  end

  describe "search_users/2" do
    test "matches by email prefix, case-insensitive" do
      user = user_fixture(%{"email" => "findme@example.com", "name" => "Someone"})

      results = Accounts.search_users("FINDME")
      assert Enum.map(results, & &1.id) == [user.id]
    end

    test "matches by name prefix" do
      user = user_fixture(%{"name" => "Pelana del Barrio"})

      results = Accounts.search_users("pelana")
      assert Enum.map(results, & &1.id) == [user.id]
    end

    test "does NOT match mid-string (prefix only)" do
      user_fixture(%{"name" => "Pelana del Barrio"})

      # "del" appears mid-name but not at the start — prefix search excludes it.
      assert Accounts.search_users("del") == []
    end

    test "queries shorter than 3 chars return no results" do
      user_fixture(%{"email" => "ab@example.com", "name" => "Ab"})

      assert Accounts.search_users("a") == []
      assert Accounts.search_users("ab") == []
      assert Accounts.search_users("") == []
    end

    test "LIKE wildcards in the query are escaped, not treated as patterns" do
      user_fixture(%{"email" => "percent100@example.com"})
      user_fixture(%{"email" => "other@example.com"})

      # A bare "%" would match EVERY row if unescaped; escaped it matches
      # only emails/names containing a literal "%" — none here. Also < 3 chars.
      assert Accounts.search_users("%") == []

      # "_" is a single-char wildcard in LIKE; escaped it matches literally.
      assert Accounts.search_users("_") == []
    end

    test "literal percent sign in the stored value still matches from the start" do
      user = user_fixture(%{"name" => "50% descuento hoy"})

      results = Accounts.search_users("50%")
      assert Enum.map(results, & &1.id) == [user.id]
    end
  end
end
