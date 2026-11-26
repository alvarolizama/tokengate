defmodule Tokengate.Repo.Migrations.SplitCodingArchDebugPreset do
  @moduledoc """
  Splits the `coding_arch_debug` use case into `coding_arch` (plan the
  architecture) and `coding_audit` (audit code, find bugs).

  One lane was doing two different jobs and the classifier had no signal to
  choose between them: "design the module boundaries for this feature" and
  "this stack trace blows up under concurrency" both landed in the same
  critical model, with the same prompt-saving knobs.

  Existing data is migrated in place, per version:

    1. the row with `key = 'coding_arch_debug'` is renamed to `coding_arch`, so
       it keeps its id, its destinations and anything pointing at it;
    2. a sibling `coding_audit` row is inserted for the same version, copying
       every flag and knob from it;
    3. that sibling gets the same `router_use_case_models` destinations (the
       operator tunes them afterwards — the point of the split is that the two
       lanes can end up with different models);
    4. `router_rules.target_use_case_keys` entries naming the old key point at
       `coding_arch`, the conservative half: a rule written for "arch/debug"
       keeps routing to the lane that inherited its identity.

  `down/0` reverses the rename, drops the `coding_audit` rows (their
  destinations cascade) and rewrites the rule keys back. Destinations an
  operator added to `coding_audit` after the split are lost on rollback — that
  is the honest cost of undoing a split.
  """

  use Ecto.Migration

  @old_key "coding_arch_debug"
  @arch_key "coding_arch"
  @audit_key "coding_audit"

  @arch_name "Diseño de arquitectura"

  @arch_description "Planear arquitectura: límites de módulos, trade-offs, diseño de APIs y " <>
                      "decisiones que cuestan re-trabajo. El trabajo es decidir y dejar el plan escrito, no el diff."

  @audit_name "Auditoría de código y bugs"

  @audit_description "Auditar código, encontrar bugs y llegar a causa raíz: leer archivos, " <>
                       "stacktraces, concurrencia y casos borde. El trabajo es probar y refutar, no proponer el diseño."

  @old_name "Arquitectura y depuración"

  @old_description "Arquitectura, trade-offs, causa raíz de bugs y concurrencia. " <>
                     "Un error aquí cuesta varios turnos de re-pregunta, así que el gate se invierte: gana el crítico."

  def up do
    # 1. Rename: the existing row becomes the architecture lane.
    execute("""
    UPDATE router_use_cases
       SET key = '#{@arch_key}',
           name = #{q(@arch_name)},
           description = #{q(@arch_description)},
           updated_at = now()
     WHERE key = '#{@old_key}'
    """)

    # 2. One audit sibling per version that had the old key, same flags/knobs.
    execute("""
    INSERT INTO router_use_cases (
      id, router_config_id, key, name, description, tags,
      requires_tools, requires_vision, requires_structured_output,
      critical_accuracy, allow_downgrade, pin_session,
      keep_last_n_images, max_history_turns, compact_json,
      stale_tool_trim_threshold_pct, priority, enabled, fallback_model_id,
      inserted_at, updated_at
    )
    SELECT gen_random_uuid(), arch.router_config_id, '#{@audit_key}',
           #{q(@audit_name)}, #{q(@audit_description)},
           ARRAY['code', 'audit', 'bugs', 'debug', 'review', 'reasoning']::varchar[],
           arch.requires_tools, arch.requires_vision, arch.requires_structured_output,
           arch.critical_accuracy, arch.allow_downgrade, arch.pin_session,
           arch.keep_last_n_images, arch.max_history_turns, arch.compact_json,
           arch.stale_tool_trim_threshold_pct, 55, arch.enabled, arch.fallback_model_id,
           now(), now()
      FROM router_use_cases arch
     WHERE arch.key = '#{@arch_key}'
       AND NOT EXISTS (
         SELECT 1 FROM router_use_cases audit
          WHERE audit.router_config_id = arch.router_config_id
            AND audit.key = '#{@audit_key}'
       )
    """)

    # 3. Same destinations for the new lane (the operator tunes them afterwards).
    execute("""
    INSERT INTO router_use_case_models (
      id, router_use_case_id, target_model_id, effort_tier, effort_override,
      supports_tools, supports_vision, supports_structured_output, min_confidence,
      tags, flags, priority, enabled, inserted_at, updated_at
    )
    SELECT gen_random_uuid(), audit.id, m.target_model_id, m.effort_tier, m.effort_override,
           m.supports_tools, m.supports_vision, m.supports_structured_output, m.min_confidence,
           m.tags, m.flags, m.priority, m.enabled, now(), now()
      FROM router_use_case_models m
      JOIN router_use_cases arch ON arch.id = m.router_use_case_id
      JOIN router_use_cases audit
        ON audit.router_config_id = arch.router_config_id
       AND audit.key = '#{@audit_key}'
     WHERE arch.key = '#{@arch_key}'
    ON CONFLICT (router_use_case_id, target_model_id, effort_tier) DO NOTHING
    """)

    # 4. Rules written against the old key keep routing to the lane that
    #    inherited its identity.
    execute("""
    UPDATE router_rules
       SET target_use_case_keys =
             array_replace(target_use_case_keys, '#{@old_key}', '#{@arch_key}'),
           updated_at = now()
     WHERE '#{@old_key}' = ANY (target_use_case_keys)
    """)
  end

  def down do
    execute("""
    UPDATE router_rules
       SET target_use_case_keys =
             array_replace(target_use_case_keys, '#{@arch_key}', '#{@old_key}'),
           updated_at = now()
     WHERE '#{@arch_key}' = ANY (target_use_case_keys)
    """)

    execute("DELETE FROM router_use_cases WHERE key = '#{@audit_key}'")

    execute("""
    UPDATE router_use_cases
       SET key = '#{@old_key}',
           name = #{q(@old_name)},
           description = #{q(@old_description)},
           updated_at = now()
     WHERE key = '#{@arch_key}'
    """)
  end

  # Single-quoted SQL literal with the embedded quotes doubled: the descriptions
  # carry accents (fine) and the odd apostrophe (not fine unescaped).
  defp q(text), do: "'" <> String.replace(text, "'", "''") <> "'"
end
