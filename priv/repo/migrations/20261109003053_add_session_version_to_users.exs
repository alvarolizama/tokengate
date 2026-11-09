defmodule Tokengate.Repo.Migrations.AddSessionVersionToUsers do
  @moduledoc """
  Revocación de sesiones por usuario.

  La cookie de sesión solo lleva `user_id`, así que hasta ahora no había forma de
  invalidar una cookie ya emitida: suspender a alguien o cambiarle la contraseña
  dejaba vivas todas las sesiones abiertas (hallazgo Crítico 1 de la auditoría).

  `session_version` es el contador que lo permite: se guarda en la sesión al
  emitirla y se compara contra la fila en cada request; subirlo mata todas las
  cookies anteriores de ese usuario.

  Nace en 0 y `NOT NULL` para que la comparación no tenga que tratar con NULL ni
  con filas viejas: las sesiones emitidas antes de esta migración se tratan como
  versión 0 (ver `Tokengate.Accounts.session_valid?/2`).
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :session_version, :integer, null: false, default: 0
    end
  end
end
