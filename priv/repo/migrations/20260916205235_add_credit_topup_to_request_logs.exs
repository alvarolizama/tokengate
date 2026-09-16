defmodule Tokengate.Repo.Migrations.AddCreditTopupToRequestLogs do
  @moduledoc """
  Añade `request_logs.credit_topup_id`.

  El log pasa a registrar **qué se debitó** además del monto: un top-up
  (`credit_topup_id`) o el límite mensual del sujeto (ambos NULL = límite del
  sujeto / sin débito). Es la contraparte del viejo `credit_subscription_id`,
  que se conserva como evidencia histórica del modelo anterior.

  `request_logs` es una tabla particionada nativa por RANGE: los ALTER sobre la
  tabla padre cascadean a los hijos automáticamente (mismo patrón que
  `20260808055508_add_missing_indexes_to_request_logs`). Sin índice: el consumo
  por top-up se agrega por id (selectivo) y el volumen no lo justifica.
  """

  use Ecto.Migration

  def up do
    alter table(:request_logs) do
      add :credit_topup_id, :binary_id
    end
  end

  def down do
    alter table(:request_logs) do
      remove :credit_topup_id
    end
  end
end
