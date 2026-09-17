defmodule Tokengate.RulesProbeTest do
  @moduledoc """
  PROBE TEMPORAL (no forma parte de la suite) — verifica contra la base real
  las tres reglas del modelo de crédito enunciadas por el usuario:

    1. un usuario sin sub no tiene presupuesto ni crédito;
    2. el ilimitado solo se consigue agregándose a un grupo ilimitado;
    3. un usuario sin grupo, solo con top-up, puede tener crédito.

  Cada test imprime lo que hace hoy el sistema; se borra después de usarlo.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Credits}

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "p#{System.unique_integer([:positive])}@example.com",
        "name" => "Probe",
        "password" => "ValidPassword123"
      })

    user
  end

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(%{"name" => "G#{System.unique_integer([:positive])}"}, attrs)
      )

    group
  end

  # Igual que `UsersLive.handle_event("create_key", ...)`: la key es del
  # usuario, sin exigir membresía.
  defp key_for(user) do
    {token, hash, prefix} = Accounts.generate_api_key_material()

    {:ok, _} =
      Accounts.create_api_key(%{
        "subject_type" => "member",
        "user_id" => user.id,
        "key_hash" => hash,
        "key_prefix" => prefix,
        "status" => "active"
      })

    token
  end

  test "R3 — usuario SIN grupo con top-up: ¿autentica el proxy?" do
    user = user_fixture()
    {:ok, _topup} = Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => "10.00"})
    token = key_for(user)

    result = Accounts.resolve_auth_by_api_key(token)
    IO.inspect(result, label: "R3 · resolve_auth_by_api_key (sin grupo, con top-up)")

    assert result == :error
  end

  test "R2 — usuario SIN grupo con unlimited_spend propio" do
    user = user_fixture()
    {:ok, user} = Accounts.update_user(user, %{"unlimited_spend" => true})

    limit = Credits.user_limit(user, nil)
    IO.inspect(limit, label: "R2 · user_limit(user, sin grupo)")

    assert limit.unlimited?
  end

  test "R1 — usuario SIN grupo con monthly_spend_limit_usd propio" do
    user = user_fixture()
    {:ok, user} = Accounts.update_user(user, %{"monthly_spend_limit_usd" => "100.00"})

    limit = Credits.user_limit(user, nil)
    IO.inspect(limit, label: "R1 · user_limit(user, sin grupo)")

    assert Decimal.equal?(limit.limit_usd, Decimal.new("100.00"))
  end

  test "R3b — usuario CON grupo sin límite + top-up: plan vigente" do
    user = user_fixture()
    group = group_fixture()
    {:ok, _m} = Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})
    {:ok, _t} = Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => "10.00"})
    token = key_for(user)

    entry = Accounts.resolve_auth_by_api_key(token)

    IO.inspect(entry && entry.limits[:credit_plan],
      label: "R3b · plan (grupo sin límite + top-up)"
    )

    assert %{member: %{}} = entry
  end

  test "R2b — usuario CON grupo ilimitado: hereda ilimitado" do
    user = user_fixture()
    group = group_fixture(%{"unlimited_spend" => true})
    {:ok, _m} = Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    limit = Credits.user_limit(Accounts.get_user!(user.id), group)
    IO.inspect(limit, label: "R2b · user_limit(user, grupo ilimitado)")

    assert limit.unlimited?
    assert limit.source == :group
  end
end
