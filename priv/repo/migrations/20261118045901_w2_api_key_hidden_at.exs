defmodule Tokengate.Repo.Migrations.W2ApiKeyHiddenAt do
  use Ecto.Migration

  # Soft-hide for API keys: deleting a key must stop it from appearing on any
  # surface while keeping the row (and therefore the `request_logs` attribution
  # by `api_key_id`, which has no FK) intact.
  #
  # The partial indexes back the two listing queries (`list_api_keys_for_user/1`
  # and `list_api_keys_for_service/1` + the `_all` mirrors) and only cover the
  # visible rows, so their size follows the live keys, not the whole history.
  # `change/0` is reversible: `down` drops the indexes and the column.
  def change do
    alter table(:api_keys) do
      add :hidden_at, :utc_datetime
    end

    create index(:api_keys, [:user_id, :inserted_at],
             where: "hidden_at IS NULL",
             name: :api_keys_user_visible_idx
           )

    create index(:api_keys, [:service_id, :inserted_at],
             where: "hidden_at IS NULL",
             name: :api_keys_service_visible_idx
           )
  end
end
