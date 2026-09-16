defmodule Tokengate.Repo.Migrations.AddProviderPathOverrides do
  use Ecto.Migration

  # Per-provider path overrides, keyed by service (chat, models, embeddings,
  # rerank, stt, tts, image, video, music). An empty object is the no-op
  # default: every service resolves to the generic OpenAI-compatible path,
  # with `Catalog.@customizations` (`:paths`) still overriding it in code.
  #
  # This is operational configuration, not catalog identity: builtins keep
  # their catalog name/base_url/dialect while the operator tunes the paths
  # (see `Provider.lock_builtin_identity/1`, which only strips identity).
  def change do
    alter table(:providers) do
      add :path_overrides, :map, default: %{}, null: false
    end
  end
end
