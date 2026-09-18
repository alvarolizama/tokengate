defmodule Tokengate.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Idioma de la UI: "en" (reserva; el msgid es la fuente) o "es". Lo
      # persiste el selector del sidebar.
      add :locale, :string, default: "en", null: false
    end
  end
end
