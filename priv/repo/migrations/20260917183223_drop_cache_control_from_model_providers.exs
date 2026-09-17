defmodule Tokengate.Repo.Migrations.DropCacheControlFromModelProviders do
  use Ecto.Migration

  # El gateway dejó de inyectar el breakpoint `cache_control` (estilo Anthropic)
  # en el prefijo system: los upstreams que tipan `content` como string —
  # Cerebras, Fireworks — lo rechazan con un 400 y tiraban la request entera.
  # El flag por model_provider se va con el injector.
  def up do
    alter table(:model_providers) do
      remove :cache_control_enabled
    end
  end

  def down do
    alter table(:model_providers) do
      add :cache_control_enabled, :boolean, default: false, null: false
    end
  end
end
