defmodule Tokengate.Repo.Migrations.DropCreditSubscriptions do
  @moduledoc """
  Backfill de la migración «eliminar suscripciones» + DROP de la tabla vieja.

  Regla dura (decisión del usuario): **la migración de producción no puede
  cortar tráfico**. Por eso el orden es backfill primero, drop después, en la
  misma migración:

    1. límite mensual por sujeto desde la sub que HOY lo gobierna;
    2. `unlimited_spend = true` para quien hoy no tiene sub (tier 3 = ilimitado);
    3. top-ups vigentes → filas de `credit_topups` con su remanente;
    4. DROP de `groups.default_subscription_id`, `services.subscription_id`
       y de `credit_subscriptions`.

  Unidades: 1 crédito = $1 (`Credits` usa micro-USD a escala 1:1), así que
  `units` se copia tal cual a `monthly_spend_limit_usd`.

  Casos especiales (registrados en el ledger):
  * **Rollover: se pierde** (decisión del usuario). Se migra solo `units`.
  * **`reset_day`: el ciclo pasa a mes calendario UTC** (decisión del usuario).
    El campo desaparece con la tabla.
  * **Sub pausada o vencida**: se migra igual que activa (límite = `units`).
    Pausar era «revoca, no libera»: no se le abre la mano a nadie.
  * **Sub compartida por varios servicios**: el monto se REPLICA por servicio
    (cada servicio ya drenaba su propio bolsín). En dev no hay casos.
  * **`request_logs.credit_subscription_id` NO se dropea**: es la única
    evidencia histórica del débito del modelo viejo.

  El `down` recrea la estructura (tabla y columnas), no los datos: el modelo
  viejo ya no tiene fuente de verdad una vez migrado.
  """

  use Ecto.Migration

  # Sub pausada o vencida también migra su `units` (ver módulo).
  @group_limit """
  UPDATE groups g
  SET monthly_spend_limit_usd = s.units,
      unlimited_spend = false,
      updated_at = now()
  FROM credit_subscriptions s
  WHERE g.default_subscription_id = s.id
    AND g.default_subscription_id IS NOT NULL
  """

  @user_limit """
  UPDATE users u
  SET monthly_spend_limit_usd = s.units,
      unlimited_spend = false,
      updated_at = now()
  FROM credit_subscriptions s
  WHERE s.user_id = u.id
    AND s.recurrence = 'monthly'
  """

  # Solo las subs RECURRENTES son límite mensual. Una sub one-shot de un
  # servicio (`recurrence = 'none'`) es un top-up y se migra abajo, en
  # `credit_topups` — contarla aquí sería doble camino de gasto para el mismo
  # techo (el probe post lo detectó: ci-eval-bot sumaba su one-shot dos veces).
  @service_limit """
  UPDATE services sv
  SET monthly_spend_limit_usd = s.units,
      unlimited_spend = false,
      updated_at = now()
  FROM credit_subscriptions s
  WHERE sv.subscription_id = s.id
    AND sv.subscription_id IS NOT NULL
    AND s.recurrence = 'monthly'
  """

  # Sin sub aplicable HOY = tier 3 (ilimitado): se marca explícito para que
  # «sin límite = bloqueado» empiece a regir recién a partir de aquí.
  @group_unlimited """
  UPDATE groups g
  SET unlimited_spend = true,
      updated_at = now()
  WHERE g.default_subscription_id IS NULL
    AND g.monthly_spend_limit_usd IS NULL
  """

  # Un usuario es tier 3 solo si NINGÚN grupo suyo está gateado y no tiene
  # sub directa propia. Si alguno de sus grupos tiene límite, lo hereda.
  @user_unlimited """
  UPDATE users u
  SET unlimited_spend = true,
      updated_at = now()
  WHERE u.unlimited_spend = false
    AND u.monthly_spend_limit_usd IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM group_members gm
      JOIN groups g ON g.id = gm.group_id
      WHERE gm.user_id = u.id
        AND g.monthly_spend_limit_usd IS NOT NULL
    )
  """

  @service_unlimited """
  UPDATE services sv
  SET unlimited_spend = true,
      updated_at = now()
  WHERE sv.subscription_id IS NULL
    AND sv.monthly_spend_limit_usd IS NULL
  """

  # Top-up vigente: se migra el REMANENTE (units − gasto atribuido), no los
  # units completos — el gasto ya está asentado en los logs. Uno agotado
  # (remanente 0) o vencido no se migra: no otorga nada.
  @topup_backfill """
  INSERT INTO credit_topups
    (id, user_id, service_id, amount_usd, status, expires_in_days, expires_at,
     label, note, inserted_at, updated_at)
  SELECT
    s.id,
    s.user_id,
    sv.id,
    GREATEST(s.units::numeric
             - COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                          WHERE rl.credit_subscription_id = s.id), 0), 0),
    'active',
    NULL,
    s.expires_at,
    s.name,
    'migrado desde credit_subscriptions',
    now(),
    now()
  FROM credit_subscriptions s
  LEFT JOIN services sv ON sv.subscription_id = s.id
  WHERE s.recurrence = 'none'
    AND s.status = 'active'
    AND (s.expires_at IS NULL OR s.expires_at > now())
    AND GREATEST(s.units::numeric
                 - COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                              WHERE rl.credit_subscription_id = s.id), 0), 0) > 0
  """

  def up do
    # ---- 1. límites por sujeto ------------------------------------------
    execute(@group_limit)
    execute(@user_limit)
    execute(@service_limit)

    # ---- 2. ilimitado explícito para quien hoy lo era ------------------
    execute(@group_unlimited)
    execute(@user_unlimited)
    execute(@service_unlimited)

    # ---- 3. top-ups vigentes -------------------------------------------
    execute(@topup_backfill)

    # ---- 4. drop del modelo viejo --------------------------------------
    alter table(:groups) do
      remove :default_subscription_id
    end

    alter table(:services) do
      remove :subscription_id
    end

    drop table(:credit_subscriptions)
  end

  def down do
    # Estructura solamente — los datos del modelo viejo no son recuperables.
    create table(:credit_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id)
      add :name, :string
      add :units, :bigint, null: false, default: 0
      add :recurrence, :string, null: false, default: "monthly"
      add :reset_day, :integer
      add :rollover_mode, :string, null: false, default: "reset"
      add :rollover_pct, :integer
      add :rollover_cap_units, :bigint
      add :status, :string, null: false, default: "active"
      add :starts_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    alter table(:groups) do
      add :default_subscription_id, references(:credit_subscriptions, type: :binary_id)
    end

    alter table(:services) do
      add :subscription_id, references(:credit_subscriptions, type: :binary_id)
    end
  end
end
