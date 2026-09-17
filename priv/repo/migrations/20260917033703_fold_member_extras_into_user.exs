defmodule Tokengate.Repo.Migrations.FoldMemberExtrasIntoUser do
  use Ecto.Migration

  @moduledoc """
  Conc/RPM pasa a resolverse con UNA sola regla en ambos sujetos:

      propio || contenedor || default

  Antes el miembro **sumaba** su extra al default del grupo
  (`combine_integer/2`) mientras el servicio era absoluto. El extra por
  miembro ya no tiene UI (se retiró en `6cd3cf4`), así que era una fuente de
  límites alcanzable solo por DB.

  Esta migración **no le quita límite a nadie**: el efectivo de cada miembro
  (`default del grupo + extra del miembro`) se pliega en el default PROPIO
  del usuario, que es el nuevo eslabón «propio» de la regla. Nunca pisa un
  override propio ya fijado (`IS NULL` en el `WHERE`).

  Determinista: si un usuario tuviera más de una membresía (modelo viejo,
  antes de `20260917011526_one_monthly_sub_per_user`), se pliega la membresía
  **más antigua** — la misma que `Accounts.member_for_key/1` resuelve para sus
  API keys (`order_by: [asc: gm.inserted_at]`), así que el efectivo de la key
  vigente es el que se preserva.
  """

  # `groups.default_concurrency_limit` / `default_rpm_limit` son NOT NULL con
  # default 5/60: no hace falta COALESCE sobre la base.
  def up do
    execute("""
    UPDATE users
       SET default_concurrency_limit = src.base + COALESCE(src.extra, 0)
      FROM (
        SELECT DISTINCT ON (gm.user_id)
               gm.user_id,
               g.default_concurrency_limit AS base,
               gm.extra_concurrency AS extra
          FROM group_members gm
          JOIN groups g ON g.id = gm.group_id
         ORDER BY gm.user_id, gm.inserted_at ASC
      ) AS src
     WHERE users.id = src.user_id
       AND users.default_concurrency_limit IS NULL
    """)

    execute("""
    UPDATE users
       SET default_rpm_limit = src.base + COALESCE(src.extra, 0)
      FROM (
        SELECT DISTINCT ON (gm.user_id)
               gm.user_id,
               g.default_rpm_limit AS base,
               gm.extra_rpm AS extra
          FROM group_members gm
          JOIN groups g ON g.id = gm.group_id
         ORDER BY gm.user_id, gm.inserted_at ASC
      ) AS src
     WHERE users.id = src.user_id
       AND users.default_rpm_limit IS NULL
    """)

    alter table(:group_members) do
      remove :extra_concurrency
      remove :extra_rpm
    end
  end

  def down do
    alter table(:group_members) do
      add :extra_concurrency, :integer
      add :extra_rpm, :integer
    end

    # El plegado es irreversible en los datos: el default propio del usuario ya
    # es el efectivo y no se puede repartir de vuelta al miembro sin inventar
    # un reparto. Las columnas vuelven vacías (como estaban en la mayoría de
    # los casos: el extra solo existía si alguien lo puso por DB).
  end
end
