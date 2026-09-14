defmodule Tokengate.Repo.Migrations.AddProviderRequestOverrides do
  use Ecto.Migration

  def change do
    # Per model_provider request overrides. Defaults are no-ops: every
    # upstream keeps receiving the full forwarded headers and the full
    # payload the gateway builds today.
    #
    #   * extra_body — JSON object merged into the upstream body (e.g.
    #     Fireworks' `{"service_tier": "priority"}` serving-path opt-in).
    #   * omit_body_fields — keys removed from the upstream body (e.g.
    #     Fireworks rejects the OpenRouter-style `session_id` with 400).
    #   * omit_headers — forwarded headers NOT sent to this upstream.
    alter table(:model_providers) do
      add :extra_body, :map, default: %{}, null: false
      add :omit_body_fields, {:array, :string}, default: [], null: false
      add :omit_headers, {:array, :string}, default: [], null: false
    end
  end
end
