defmodule Tokengate.Credits.TopupTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Credits.Topup

  describe "changeset/2" do
    test "válido con dueño usuario: inserta" do
      user = insert_user!()

      assert {:ok, topup} =
               %Topup{}
               |> Topup.changeset(%{
                 user_id: user.id,
                 amount_usd: Decimal.new("10.500000"),
                 label: "promo"
               })
               |> Tokengate.Repo.insert()

      assert topup.user_id == user.id
      assert topup.service_id == nil
      assert topup.amount_usd == Decimal.new("10.500000")
      assert topup.status == "active"
      assert topup.expires_at == nil
    end

    test "válido con dueño servicio: changeset válido" do
      service = insert_service!()

      changeset =
        Topup.changeset(%Topup{}, %{
          service_id: service.id,
          amount_usd: Decimal.new("5")
        })

      assert changeset.valid?
    end

    test "con 0 dueños → inválido (error en :user_id)" do
      changeset =
        Topup.changeset(%Topup{}, %{amount_usd: Decimal.new("5")})

      refute changeset.valid?

      assert "must have exactly one owner (user or service)" in errors_on(changeset).user_id
    end

    test "con 2 dueños → inválido (error en :user_id)" do
      user = insert_user!()
      service = insert_service!()

      changeset =
        Topup.changeset(%Topup{}, %{
          user_id: user.id,
          service_id: service.id,
          amount_usd: Decimal.new("5")
        })

      refute changeset.valid?

      assert "must have exactly one owner (user or service)" in errors_on(changeset).user_id
    end

    test "expires_in_days: 7 ⇒ expires_at ≈ ahora + 7 días (±1 día)" do
      user = insert_user!()

      assert {:ok, topup} =
               %Topup{}
               |> Topup.changeset(%{
                 user_id: user.id,
                 amount_usd: Decimal.new("5"),
                 expires_in_days: 7
               })
               |> Tokengate.Repo.insert()

      expected_low = DateTime.add(DateTime.utc_now(), 7 * 86_400 - 86_400, :second)
      expected_high = DateTime.add(DateTime.utc_now(), 7 * 86_400 + 86_400, :second)

      assert DateTime.compare(topup.expires_at, expected_low) in [:gt, :eq]
      assert DateTime.compare(topup.expires_at, expected_high) in [:lt, :eq]
    end

    test "expires_in_days: nil ⇒ expires_at nil" do
      user = insert_user!()

      changeset =
        Topup.changeset(%Topup{}, %{
          user_id: user.id,
          amount_usd: Decimal.new("5"),
          expires_in_days: nil
        })

      assert changeset.valid?
      assert get_field(changeset, :expires_at) == nil
    end

    test "amount_usd <= 0 → inválido" do
      user = insert_user!()

      for amount <- [Decimal.new("0"), Decimal.new("-1")] do
        changeset =
          Topup.changeset(%Topup{}, %{user_id: user.id, amount_usd: amount})

        refute changeset.valid?
        assert errors_on(changeset).amount_usd
      end
    end

    test "expires_in_days: 5 (no permitido) → inválido" do
      user = insert_user!()

      changeset =
        Topup.changeset(%Topup{}, %{
          user_id: user.id,
          amount_usd: Decimal.new("5"),
          expires_in_days: 5
        })

      refute changeset.valid?
      assert errors_on(changeset).expires_in_days
    end
  end

  defp insert_user! do
    Tokengate.Repo.insert!(%Tokengate.Accounts.User{
      email: "topup-#{System.unique_integer([:positive])}@test.local",
      name: "Topup Test"
    })
  end

  defp insert_service! do
    Tokengate.Repo.insert!(%Tokengate.Accounts.Service{
      name: "topup-test-#{System.unique_integer([:positive])}"
    })
  end
end
