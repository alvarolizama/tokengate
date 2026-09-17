defmodule Tokengate.Providers.DeniedModelsTest do
  @moduledoc """
  W4: acceso efectivo a modelos por sujeto — `(perfil de límites ∪ extras) − denegados`.

  Cubre la API nueva (`list_accessible_models_for_member/1`, `deny_model/2`,
  `allow_model/2`, batch `list_accessible_models_for_members/1`) y la
  interacción entre extras y denies (quitar un extra no borra el deny).
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.{Accounts, Providers, Repo}
  alias Tokengate.Providers.GroupMemberDeniedModel

  # Fixtures por los contextos reales (los módulos `TestGroup`/`TestUser` de
  # `ProvidersTest` son privados a ESE módulo: no se pueden referenciar desde
  # otro archivo de test).

  defp group_member_fixture(group \\ nil) do
    unique = System.unique_integer([:positive])

    group =
      case group do
        nil ->
          {:ok, g} = Accounts.create_group(%{"name" => "Group #{unique}"})
          g

        %{} = g ->
          g
      end

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "denied-#{unique}@example.com",
        "name" => "Denied #{unique}",
        "password" => "ValidPassword123"
      })

    {:ok, member} =
      Accounts.create_group_member(%{"group_id" => group.id, "user_id" => user.id})

    %{member: Repo.preload(member, [:group, :user]), group: group, user: user}
  end

  defp model_fixture(name) do
    unique = System.unique_integer([:positive])
    name = name || "model-#{unique}"

    {:ok, model} = Providers.create_model(%{name: name, context_window: 128_000})

    model
  end

  defp ids(models), do: models |> Enum.map(& &1.id) |> MapSet.new()

  # Las listas 2 y 3 de `list_accessible_models_for_member/1` son IDs crudos.
  defp id_set(ids), do: MapSet.new(ids)

  # ---------------------------------------------------------------------------
  # list_accessible_models_for_member/1 — acceso efectivo (3 conjuntos)
  # ---------------------------------------------------------------------------

  describe "list_accessible_models_for_member/1" do
    test "returns {group ∪ extras − denied, extra_ids, denied_ids}" do
      %{member: member, group: group} = group_member_fixture()

      g1 = model_fixture("granted-1")
      g2 = model_fixture("granted-2")
      extra = model_fixture("extra-1")
      _other = model_fixture("not-granted")

      {:ok, _} = Providers.grant_model_to_group(group.id, g1.id)
      {:ok, _} = Providers.grant_model_to_group(group.id, g2.id)
      {:ok, _} = Providers.grant_extra_model(member.id, extra.id)
      {:ok, _} = Providers.deny_model(member.id, g2.id)

      {accessible, extra_ids, denied_ids} =
        Providers.list_accessible_models_for_member(member)

      assert ids(accessible) == ids([g1, extra])
      assert MapSet.new(extra_ids) == ids([extra])
      assert MapSet.new(denied_ids) == ids([g2])
      # El denegado NO está en accesibles aunque siga otorgado al perfil de límites.
      refute g2.id in Enum.map(accessible, & &1.id)
    end

    test "an extra model can also be denied (extras are part of the union)" do
      %{member: member, group: group} = group_member_fixture()

      extra = model_fixture("extra-denied")
      {:ok, _} = Providers.grant_extra_model(member.id, extra.id)
      {:ok, _} = Providers.deny_model(member.id, extra.id)

      {accessible, _extra_ids, denied_ids} = Providers.list_accessible_models_for_member(member)
      assert accessible == []
      assert denied_ids == [extra.id]
      # Sanity: el perfil de límites en sí no otorga nada — la resta no inventa acceso.
      assert Providers.list_accessible_models(group_member_only(group)) == []
    end

    test "returns empty sets for a member with no grants" do
      %{member: member} = group_member_fixture()

      assert {[], [], []} = Providers.list_accessible_models_for_member(member)
    end

    test "deny then allow of a group model round-trips the access" do
      %{member: member, group: group} = group_member_fixture()

      model_ = model_fixture(nil)
      {:ok, _} = Providers.grant_model_to_group(group.id, model_.id)

      assert {models, [], []} = Providers.list_accessible_models_for_member(member)
      assert ids(models) == ids([model_])

      {:ok, _} = Providers.deny_model(member.id, model_.id)
      assert {[], [], denied} = Providers.list_accessible_models_for_member(member)
      assert id_set(denied) == id_set([model_.id])

      # Allow restaura el acceso heredado.
      {:ok, _} = Providers.allow_model(member.id, model_.id)
      assert {models, [], []} = Providers.list_accessible_models_for_member(member)
      assert ids(models) == ids([model_])
    end
  end

  # ---------------------------------------------------------------------------
  # Mutaciones deny / allow
  # ---------------------------------------------------------------------------

  describe "deny_model/2" do
    test "inserts the deny row and is idempotent" do
      %{member: member} = group_member_fixture()
      model_ = model_fixture(nil)

      assert {:ok, %GroupMemberDeniedModel{}} = Providers.deny_model(member.id, model_.id)
      assert {:error, :already_denied} = Providers.deny_model(member.id, model_.id)

      assert Repo.get_by(GroupMemberDeniedModel,
               group_member_id: member.id,
               model_id: model_.id
             )
    end

    test "rejects unknown model / member with :not_found" do
      %{member: member} = group_member_fixture()
      assert {:error, :not_found} = Providers.deny_model(member.id, Ecto.UUID.generate())

      assert {:error, :not_found} =
               Providers.deny_model(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "allow_model/2" do
    test "removes the deny row (undeny) and is idempotent" do
      %{member: member} = group_member_fixture()
      model_ = model_fixture(nil)

      assert {:ok, nil} = Providers.allow_model(member.id, model_.id)

      {:ok, _} = Providers.deny_model(member.id, model_.id)
      assert {:ok, %GroupMemberDeniedModel{}} = Providers.allow_model(member.id, model_.id)
      assert {:ok, nil} = Providers.allow_model(member.id, model_.id)

      refute Repo.get_by(GroupMemberDeniedModel,
               group_member_id: member.id,
               model_id: model_.id
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Interacción extras ↔ denies
  # ---------------------------------------------------------------------------

  describe "extra grants vs denies" do
    test "revoking an extra keeps the deny row; both rows coexist" do
      %{member: member} = group_member_fixture()
      model_ = model_fixture(nil)

      {:ok, _} = Providers.grant_extra_model(member.id, model_.id)
      {:ok, _} = Providers.deny_model(member.id, model_.id)

      # Ambas filas coexisten; el acceso lo decide la resta.
      assert Repo.get_by(Tokengate.Providers.GroupMemberExtraModel,
               group_member_id: member.id,
               model_id: model_.id
             )

      assert Repo.get_by(GroupMemberDeniedModel,
               group_member_id: member.id,
               model_id: model_.id
             )

      {_, extra_ids, denied_ids} = Providers.list_accessible_models_for_member(member)

      assert id_set(extra_ids) == id_set([model_.id])
      assert id_set(denied_ids) == id_set([model_.id])

      # Quitar el extra no borra el deny.
      {:ok, _} = Providers.revoke_extra_model(member.id, model_.id)

      assert Repo.get_by(GroupMemberDeniedModel,
               group_member_id: member.id,
               model_id: model_.id
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Batch
  # ---------------------------------------------------------------------------

  describe "list_accessible_models_for_members/1 (batch)" do
    test "applies the per-member subtraction in one call" do
      # Los dos miembros del MISMO perfil de límites (una lista de grant por perfil de límites, no dos).
      %{member: m1, group: group} = group_member_fixture()
      %{member: m2} = group_member_fixture(group)

      g1 = model_fixture("batch-g1")
      g2 = model_fixture("batch-g2")
      extra = model_fixture("batch-extra")

      {:ok, _} = Providers.grant_model_to_group(group.id, g1.id)
      {:ok, _} = Providers.grant_model_to_group(group.id, g2.id)
      {:ok, _} = Providers.grant_extra_model(m1.id, extra.id)
      {:ok, _} = Providers.deny_model(m1.id, g2.id)
      {:ok, _} = Providers.deny_model(m2.id, g1.id)

      result =
        Providers.list_accessible_models_for_members([
          Repo.preload(m1, :group),
          Repo.preload(m2, :group)
        ])
        |> Map.new(fn {id, models} -> {id, models} end)

      assert MapSet.new(Enum.map(result[m1.id], & &1.id)) == ids([g1, extra])
      assert MapSet.new(Enum.map(result[m2.id], & &1.id)) == ids([g2])
      refute Map.get(result, m1.id) |> Enum.map(& &1.id) |> Enum.member?(g2.id)
      refute Map.get(result, m2.id) |> Enum.map(& &1.id) |> Enum.member?(g1.id)
    end

    test "returns an empty map for a member list without grants" do
      %{member: member} = group_member_fixture()

      assert %{} == Providers.list_accessible_models_for_members([member])
    end
  end

  # Helper mínimo para el sanity-check del caso "extra denegado": member sin
  # preload fresco pero con group cargado.
  defp group_member_only(group), do: %{id: Ecto.UUID.generate(), group: group, service_name: nil}
end
