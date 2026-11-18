defmodule Tokengate.Repo.Migrations.W6ServicesNameUnique do
  use Ecto.Migration

  # `Service.changeset/2` declares `unique_constraint(:name)`, so the database
  # has to back that constraint with a real unique index: otherwise two
  # services could share a name and the changeset message would never trigger
  # (the name is how operators pick a service in every admin surface).
  #
  # `change/0` is reversible: rolling back drops the index.
  def change do
    create unique_index(:services, [:name], name: :services_name_unique)
  end
end
