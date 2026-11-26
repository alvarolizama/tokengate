defmodule Tokengate.SmartRouter.Presets do
  @moduledoc """
  The shipped SmartRouter use-case presets, and the idempotent seeder.

  Thirteen specialties cover this operator's real traffic mix (software
  development > data analysis > presentations > systems/chatbots/summaries):

  #{Enum.map_join(~w(fast writing presentations coding_implement coding_arch
      coding_audit data_heavy_finance research computer_use modeling_3d
      vision_extraction structured_etl translation_i18n), ", ", &"`#{&1}`")}

  `coding_arch` and `coding_audit` are two lanes on purpose: planning a
  structure and hunting a bug both want a critical model, but they ask for
  different work — one decides and writes the plan, the other reads code,
  stack traces and edge cases to refute it — and collapsing them into a single
  `coding_arch_debug` made the classifier pick between them by coin flip.

  They ship **without destinations**: binding models to a use case is an
  operator decision (the same model can be a valid destination for `writing`
  and an invalid one for `computer_use`), so a freshly migrated or freshly
  booted instance has the specialties and zero `router_use_case_models` rows.

  ## Idempotent by key

  `ensure_all!/1` inserts only the presets whose `key` is missing **in the
  target version** (`ON CONFLICT (router_config_id, key) DO NOTHING`). A use
  case that already exists is **never** overwritten: once the operator edits a
  preset — renames it, flips a knob, binds models — re-running the seeder must
  not undo that. It is safe on every boot, on every seed run, and from the
  admin page.

  The keys are the public identity of a use case *within a version* (rules
  target keys, not ids), so they are also the conflict target of the insert.
  `ensure_all!/1` defaults to the serving Default, so a freshly migrated
  instance seeds exactly one catalogue; passing a cloned version's id seeds
  that version instead, and a clone can then hold the same thirteen keys as the
  Default.
  """

  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Config
  alias Tokengate.SmartRouter.UseCase

  @presets [
    %{
      key: "fast",
      name: "Respuesta rápida",
      description:
        "Chats, respuestas de sistema, resúmenes cortos y extracción simple. " <>
          "El tráfico trivial del día: TTFT corto y el modelo más barato que responda.",
      tags: ~w(chat summary extraction short),
      requires_tools: false,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 12,
      compact_json: false,
      stale_tool_trim_threshold_pct: nil,
      priority: 10
    },
    %{
      key: "writing",
      name: "Redacción",
      description:
        "Redacción estándar: correos, documentación, reportes de texto. " <>
          "El criterio es prosa correcta y sostenida, no código ni datos.",
      tags: ~w(writing docs email prose),
      requires_tools: false,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 20,
      compact_json: false,
      stale_tool_trim_threshold_pct: nil,
      priority: 20
    },
    %{
      key: "presentations",
      name: "Presentaciones",
      description:
        "Diseño de presentaciones: storyline, estructura de slides, narrativa visual. " <>
          "Redactar bien no basta; aquí manda la estructura.",
      tags: ~w(presentations deck storyline design),
      requires_tools: false,
      requires_vision: false,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: 1,
      max_history_turns: 24,
      compact_json: true,
      stale_tool_trim_threshold_pct: 40,
      priority: 30
    },
    %{
      key: "coding_implement",
      name: "Implementación de código",
      description:
        "Implementar: endpoints, tests, scripts y refactors acotados. " <>
          "Especificación clara + herramientas; el trabajo es escribir, no decidir arquitectura.",
      tags: ~w(code implementation tests tools),
      requires_tools: true,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 40,
      compact_json: false,
      stale_tool_trim_threshold_pct: 60,
      priority: 40
    },
    %{
      key: "coding_arch",
      name: "Diseño de arquitectura",
      description:
        "Planear arquitectura: límites de módulos, trade-offs, diseño de APIs y " <>
          "decisiones que cuestan re-trabajo. El trabajo es decidir y dejar el plan escrito, no el diff.",
      tags: ~w(code architecture design planning reasoning),
      requires_tools: true,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: true,
      allow_downgrade: false,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 60,
      compact_json: false,
      stale_tool_trim_threshold_pct: 70,
      priority: 50
    },
    %{
      key: "coding_audit",
      name: "Auditoría de código y bugs",
      description:
        "Auditar código, encontrar bugs y llegar a causa raíz: leer archivos, " <>
          "stacktraces, concurrencia y casos borde. El trabajo es probar y refutar, no proponer el diseño.",
      tags: ~w(code audit bugs debug review reasoning),
      requires_tools: true,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: true,
      allow_downgrade: false,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 60,
      compact_json: false,
      stale_tool_trim_threshold_pct: 70,
      priority: 55
    },
    %{
      key: "data_heavy_finance",
      name: "Datos pesados y finanzas",
      description:
        "Datos pesados, finanzas, conciliaciones y proyecciones. " <>
          "La precisión no es negociable: una cifra mal conciliada se paga dos veces.",
      tags: ~w(finance data analysis reconciliation),
      requires_tools: true,
      requires_vision: false,
      requires_structured_output: true,
      critical_accuracy: true,
      allow_downgrade: false,
      pin_session: true,
      keep_last_n_images: nil,
      max_history_turns: 30,
      compact_json: true,
      stale_tool_trim_threshold_pct: nil,
      priority: 60
    },
    %{
      key: "research",
      name: "Investigación",
      description:
        "Investigación y síntesis sobre historiales largos: contexto amplio, " <>
          "varias fuentes y trazabilidad de lo citado.",
      tags: ~w(research long_context synthesis),
      requires_tools: true,
      requires_vision: false,
      requires_structured_output: false,
      critical_accuracy: true,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: 1,
      max_history_turns: 60,
      compact_json: false,
      stale_tool_trim_threshold_pct: 50,
      priority: 70
    },
    %{
      key: "computer_use",
      name: "Computer use",
      description:
        "Agentes que operan navegador o escritorio: visión obligatoria, herramientas " <>
          "y el loop de herramientas fijado al modelo que lo abrió.",
      tags: ~w(agent browser vision tools),
      requires_tools: true,
      requires_vision: true,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: false,
      pin_session: true,
      keep_last_n_images: 2,
      max_history_turns: 30,
      compact_json: true,
      stale_tool_trim_threshold_pct: 80,
      priority: 80
    },
    %{
      key: "modeling_3d",
      name: "Modelado 3D",
      description: "Modelado y geometría: código paramétrico, mallas y parámetros estructurados.",
      tags: ~w(3d geometry code structured),
      requires_tools: true,
      requires_vision: true,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: true,
      keep_last_n_images: 3,
      max_history_turns: 30,
      compact_json: true,
      stale_tool_trim_threshold_pct: 50,
      priority: 90
    },
    %{
      key: "vision_extraction",
      name: "Extracción visual",
      description:
        "Extraer datos de imágenes y documentos escaneados hacia un shape estructurado.",
      tags: ~w(vision extraction structured ocr),
      requires_tools: false,
      requires_vision: true,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: false,
      keep_last_n_images: 3,
      max_history_turns: 4,
      compact_json: true,
      stale_tool_trim_threshold_pct: nil,
      priority: 100
    },
    %{
      key: "structured_etl",
      name: "ETL estructurado",
      description:
        "Transformaciones por lotes con shape fijo: cada request es independiente, " <>
          "así que no hay sesión que fijar ni historial que arrastrar.",
      tags: ~w(etl data structured batch),
      requires_tools: false,
      requires_vision: false,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: false,
      keep_last_n_images: nil,
      max_history_turns: 2,
      compact_json: true,
      stale_tool_trim_threshold_pct: nil,
      priority: 110
    },
    %{
      key: "translation_i18n",
      name: "Traducción e i18n",
      description:
        "Traducción y localización, incluidos catálogos de mensajes y archivos de recursos " <>
          "donde el formato de salida tiene que ser exacto.",
      tags: ~w(translation i18n text locale),
      requires_tools: false,
      requires_vision: false,
      requires_structured_output: true,
      critical_accuracy: false,
      allow_downgrade: true,
      pin_session: false,
      keep_last_n_images: nil,
      max_history_turns: 6,
      compact_json: true,
      stale_tool_trim_threshold_pct: nil,
      priority: 120
    }
  ]

  @doc "The preset definitions, in priority order (key/name/flags/knobs)."
  def all, do: @presets

  @doc "The preset keys, in priority order."
  def keys, do: Enum.map(@presets, & &1.key)

  @doc """
  Inserts every missing preset into `router_config_id` (the serving Default
  when omitted). Idempotent and non-destructive.

  Returns `%{inserted: n, existing: m}`. A preset whose `key` already exists in
  that version is left exactly as it is — operator edits always win over the
  shipped defaults — and the same key may exist in another version.
  """
  @spec ensure_all!(String.t() | nil) :: %{
          inserted: non_neg_integer(),
          existing: non_neg_integer()
        }
  def ensure_all!(router_config_id \\ nil) do
    router_config_id = router_config_id || Config.ensure!().id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(@presets, fn preset ->
        Map.merge(preset, %{
          router_config_id: router_config_id,
          inserted_at: now,
          updated_at: now
        })
      end)

    {inserted, _} =
      Repo.insert_all(UseCase, rows,
        on_conflict: :nothing,
        conflict_target: [:router_config_id, :key]
      )

    %{inserted: inserted, existing: length(rows) - inserted}
  end
end
