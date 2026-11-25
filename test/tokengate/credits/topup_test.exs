defmodule Tokengate.Credits.TopupTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Credits.Topup
  alias Tokengate.Repo

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

  # Editar los días de un top-up que YA tiene `expires_at` era un no-op
  # silencioso: `get_field` refleja los datos, no el cambio, así que la fecha
  # se quedaba en la vieja y el crédito vencía antes de lo que el admin creía.
  test "editar expires_in_days recalcula expires_at desde la creación" do
    user = insert_user!()

    created_at =
      DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, topup} =
      %Topup{}
      |> Topup.changeset(%{
        user_id: user.id,
        amount_usd: Decimal.new("10"),
        expires_in_days: 7
      })
      |> Repo.insert()

    # El top-up "lleva 2 días de vida": la base del cálculo es la creación.
    topup =
      topup
      |> Ecto.Changeset.change(inserted_at: created_at)
      |> Repo.update!()

    {:ok, extended} =
      topup
      |> Topup.changeset(%{expires_in_days: 30})
      |> Repo.update()

    assert DateTime.diff(extended.expires_at, created_at) == 30 * 86_400

    renewed = extended.expires_at
    {:ok, same} = extended |> Topup.changeset(%{expires_in_days: 30}) |> Repo.update()

    # Idempotente: reenviar los mismos días no mueve la fecha.
    assert same.expires_at == renewed
  end

  test "un expires_at explícito en el submit gana sobre los días" do
    user = insert_user!()

    explicit =
      DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second)

    changeset =
      Topup.changeset(%Topup{}, %{
        user_id: user.id,
        amount_usd: Decimal.new("5"),
        expires_in_days: 30,
        expires_at: explicit
      })

    assert DateTime.compare(get_field(changeset, :expires_at), explicit) == :eq
  end

  test "Topups.summary/1 batches consumption lookup in one counter query for multiple topups" do
    user = insert_user!()

    for _ <- 1..4 do
      {:ok, topup} =
        Tokengate.Credits.Topups.create(%{
          "user_id" => user.id,
          "amount_usd" => "10.00"
        })

      Tokengate.Repo.insert!(%Tokengate.Metrics.TopupConsumptionCounter{
        topup_id: topup.id,
        consumed_micro: 1_000_000
      })
    end

    ref = make_ref()
    parent = self()
    hook = {__MODULE__, ref}

    :telemetry.attach(
      hook,
      [:tokengate, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta[:source] == "topup_consumption_counters" do
          send(parent, {:counter_query, ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(hook) end)

    summary = Tokengate.Credits.Topups.summary({:user, user.id})
    assert length(summary.topups) == 4
    assert Decimal.equal?(summary.remaining_topup_usd, Decimal.new("36.00"))
    assert_received {:counter_query, ^ref}
    refute_received {:counter_query, ^ref}
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
