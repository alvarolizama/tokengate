defmodule Tokengate.Repo.Migrations.OneMonthlySubPerUser do
  use Ecto.Migration

  @moduledoc """
  Un usuario pertenece a UNA sola sub mensual (antes grupo).

  El modelo de crédito resuelve el límite efectivo del usuario como «el suyo y,
  si no define ninguno, el de su grupo». Con N membresías el heredado quedaba
  ambiguo (¿cuál de los grupos?) y el read-side tenía que elegir una
  arbitrariamente. La invariante es ahora 1 membresía por usuario.

  Antes de crear el índice único se consolida la data existente: por cada
  usuario con varias membresías se conserva la MÁS RECIENTE (la activa de
  verdad) y se borran las demás. El borrado arrastra en cascada sus API keys y
  su historial de request_logs, así que este paso toca datos.

  Las tablas que referencian `group_members` sin `ON DELETE CASCADE` se limpian
  primero — si no, el `DELETE` falla por la foreign key.
  """

  def up do
    # group_member_extra_models no tiene ON DELETE CASCADE: es la única que
    # bloquea el borrado de una membresía duplicada.
    execute """
    DELETE FROM group_member_extra_models
    WHERE group_member_id IN (
      SELECT id FROM (
        SELECT id,
               row_number() OVER (
                 PARTITION BY user_id ORDER BY inserted_at DESC, id DESC
               ) AS rn
        FROM group_members
      ) ranked
      WHERE rn > 1
    )
    """

    execute """
    DELETE FROM group_members
    WHERE id IN (
      SELECT id FROM (
        SELECT id,
               row_number() OVER (
                 PARTITION BY user_id ORDER BY inserted_at DESC, id DESC
               ) AS rn
        FROM group_members
      ) ranked
      WHERE rn > 1
    )
    """

    create unique_index(:group_members, [:user_id], name: :group_members_user_id_unique_index)
  end

  def down do
    drop_if_exists index(:group_members, [:user_id], name: :group_members_user_id_unique_index)
  end
end
