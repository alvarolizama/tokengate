defmodule Tokengate.Repo.Migrations.BackfillFireworksCacheControl do
  use Ecto.Migration

  # Fireworks validates its request body strictly and rejects the Anthropic-style
  # content-parts shape that CacheControlInjector produces with a 400 (it requires
  # `content` to be a plain string). The admin form forces the flag off for
  # fireworks rows (`apply_provider_defaults/2`), but rows created by API, seeds,
  # or before that change can still carry `cache_control_enabled = true`.
  #
  # Cache-control injection is automatic on Fireworks (prefix matching), so
  # explicit breakpoints are never needed there: turn them off for every
  # fireworks-backed model_provider.
  def up do
    execute(
      """
      UPDATE model_providers mp
      SET cache_control_enabled = false
      FROM provider_credentials c
      JOIN providers p ON p.id = c.provider_id
      WHERE mp.credential_id = c.id
        AND p.key = 'fireworks'
        AND mp.cache_control_enabled = true
      """,
      "SELECT 1"
    )
  end

  # Irreversible data backfill: we cannot know which rows were flipped. Leaving
  # them at `false` is the correct, safe state regardless.
  def down, do: :ok
end
