defmodule Tokengate.Repo.Migrations.AddProviderCatalogFields do
  @moduledoc """
  Adds catalog identity fields to `providers`, drops `embedding_base_url`,
  and migrates existing rows (including production customs) onto the
  builtin catalog.

  ## What runs

    1. New columns: `key` (unique among builtins), `source`
       (`builtin|custom`), `dialect`, `capabilities`.
    2. Pre-flight: any provider whose `embedding_base_url` override points
       somewhere other than `{base_url}/embeddings` aborts the migration —
       dropping the column would silently break its embeddings. The error
       lists the offending providers so the operator fixes them first.
    3. Match existing rows to catalog entries by normalized base_url.
       Matched groups: the row with the most credentials survives, is
       stamped with the catalog key/source/dialect/capabilities, and the
       duplicates' credentials are re-pointed to it before deletion.
       Unmatched rows become `source: "custom"` (untouched otherwise).
    4. Seed the builtin catalog entries that no existing row matched.
    5. Unique index on `key` (partial, only when set), then drop
       `embedding_base_url`.
    6. Log a summary (matched / customs / merged / seeded).

  Idempotent by construction: re-running finds everything already
  matched/seeded and does nothing. Reversible: restores the dropped
  column; builtin rows seeded here that carry no credentials are removed
  on rollback (rows with credentials keep working as plain providers).
  """

  use Ecto.Migration

  require Logger

  # ── Catálogo congelado ─────────────────────────────────────────────────────
  #
  # Esta migración se escribió cuando el catálogo de proveedores vivía en
  # `Tokengate.Providers.Catalog` como lista compile-time. El refactor del
  # catálogo a models.dev eliminó esas funciones, y desde entonces la cadena
  # desde cero (drop → create → migrate) no compila: moría aquí con
  # `function Tokengate.Providers.Catalog.all/0 is undefined`.
  #
  # Una migración no puede depender de código de la app que evoluciona: se
  # congela el catálogo tal como estaba el día que se escribió (commit
  # 27b57f6) junto con sus helpers, con el mismo comportamiento que ya corrió
  # en los entornos existentes. Solo restaura la capacidad de correr la
  # cadena desde cero; en las BD donde ya está aplicada no se re-ejecuta.

  @builtin [
    %{
      key: "openrouter",
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      dialect: "openrouter",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "fireworks",
      name: "Fireworks AI",
      base_url: "https://api.fireworks.ai/inference/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "qwen_cloud",
      name: "Qwen Cloud",
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "qwen_cloud_token_plan",
      name: "Qwen Cloud (Token Plan)",
      base_url: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "opencode_zen",
      name: "OpenCode Zen",
      base_url: "https://opencode.ai/zen/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "opencode_go",
      name: "OpenCode Go",
      base_url: "https://opencode.ai/zen/go/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "kimi",
      name: "Kimi (Moonshot)",
      base_url: "https://api.moonshot.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "kimi_code",
      name: "Kimi Code (suscripción)",
      base_url: "https://api.kimi.com/coding/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "zai",
      name: "Z.AI",
      base_url: "https://api.z.ai/api/paas/v4",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "zai_coding_plan",
      name: "Z.AI (GLM Coding Plan)",
      base_url: "https://api.z.ai/api/coding/paas/v4",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "abliteration",
      name: "Abliteration",
      base_url: "https://api.abliteration.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "crof_ai",
      name: "CrofAi",
      base_url: "https://crof.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "nube",
      name: "Nube",
      base_url: "https://ai.nube.sh/api/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    }
  ]

  defp get_builtin(key) when is_binary(key), do: Enum.find(@builtin, &(&1.key == key))

  defp normalize_base_url(nil), do: nil

  defp normalize_base_url(url) when is_binary(url) do
    url |> String.trim_trailing("/") |> String.downcase()
  end

  defp match_by_base_url(nil), do: nil

  defp match_by_base_url(base_url) do
    normalized = normalize_base_url(base_url)
    Enum.find(@builtin, &(normalize_base_url(&1.base_url) == normalized))
  end

  defp embedding_override_conflict?(row) when is_map(row) do
    case Map.get(row, :embedding_base_url) do
      nil ->
        false

      "" ->
        false

      override ->
        base = Map.get(row, :base_url) || ""
        normalize_base_url(override) != normalize_base_url(base <> "/embeddings")
    end
  end

  @catalog_keys Enum.map(@builtin, & &1.key)

  def up do
    alter table(:providers) do
      add :key, :string
      add :source, :string, default: "custom", null: false
      add :dialect, :string, default: "openai", null: false
      add :capabilities, {:array, :string}, default: ["llm"], null: false
    end

    flush()

    preflight_embedding_overrides!()

    rows = fetch_providers()

    {matched_groups, customs} = classify(rows)

    merged_away =
      matched_groups
      |> Enum.map(fn {entry, group_rows} -> do_merge(entry, group_rows) end)
      |> Enum.sum()

    seeded = seed_missing_builtins(matched_groups)

    Logger.info(
      "[catalog migration] matched=#{length(matched_groups)} customs=#{length(customs)} " <>
        "merged_away=#{merged_away} seeded=#{seeded}"
    )

    flush()

    create unique_index(:providers, [:key],
             where: "key IS NOT NULL",
             name: :providers_builtin_key_unique_index
           )

    alter table(:providers) do
      remove :embedding_base_url
    end
  end

  def down do
    alter table(:providers) do
      add :embedding_base_url, :string
    end

    # Builtin rows seeded by this migration that carry no credentials are
    # removed; rows with credentials keep working as plain providers.
    # Original embedding override values cannot be restored — operators
    # who relied on them re-enter them as custom providers.
    execute """
    DELETE FROM providers
    WHERE key IS NOT NULL
      AND id NOT IN (SELECT provider_id FROM provider_credentials)
    """

    alter table(:providers) do
      remove :key
      remove :source
      remove :dialect
      remove :capabilities
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  # Abort when dropping embedding_base_url would change behaviour: the
  # provider serves embeddings from a URL that is not {base_url}/embeddings.
  defp preflight_embedding_overrides! do
    conflicts =
      fetch_providers()
      |> Enum.filter(&embedding_override_conflict?/1)
      |> Enum.map(&{&1.name, &1.base_url, &1.embedding_base_url})

    if conflicts != [] do
      raise """
      cannot drop providers.embedding_base_url: #{length(conflicts)} provider(s) \
      override the embeddings endpoint with a different URL. Fix them first \
      (align base_url or move them to custom providers):
      #{inspect(conflicts, pretty: true)}
      """
    end
  end

  # Returns {matched_groups, customs}: matched_groups is a list of
  # {catalog_entry, [rows]} for every builtin with at least one row;
  # customs are the rows matching no builtin.
  defp classify(rows) do
    matched_groups =
      @catalog_keys
      |> Enum.map(fn key ->
        entry = get_builtin(key)
        group = Enum.filter(rows, fn row -> match_key(row.base_url) == key end)
        {entry, group}
      end)
      |> Enum.reject(fn {_entry, group} -> group == [] end)

    customs = Enum.filter(rows, &(match_key(&1.base_url) == nil))
    {matched_groups, customs}
  end

  # Survivor = row with the most credentials (ties: oldest). Stamp the
  # survivor with the catalog identity, re-point duplicate rows' credentials
  # to it, delete the duplicates. Returns the number of rows merged away.
  defp do_merge(entry, rows) do
    [survivor | dupes] =
      Enum.sort_by(rows, fn row -> {-credential_count(row.id), row.inserted_at} end)

    caps = Enum.map_join(entry.capabilities, ",", &"'#{&1}'")

    execute("""
    UPDATE providers
    SET key = '#{entry.key}',
        source = 'builtin',
        dialect = '#{entry.dialect}',
        capabilities = ARRAY[#{caps}]::varchar[],
        updated_at = now()
    WHERE id = '#{survivor.id}'
    """)

    Enum.each(dupes, fn dupe ->
      execute(
        "UPDATE provider_credentials SET provider_id = '#{survivor.id}' WHERE provider_id = '#{dupe.id}'"
      )

      execute("DELETE FROM providers WHERE id = '#{dupe.id}'")
    end)

    if dupes != [] do
      Logger.info(
        "[catalog migration] builtin #{entry.key}: merged #{length(dupes)} duplicate row(s) into #{survivor.name} (#{survivor.id})"
      )
    end

    length(dupes)
  end

  # Insert catalog entries that no existing row matched.
  defp seed_missing_builtins(matched_groups) do
    matched_keys = MapSet.new(matched_groups, fn {entry, _rows} -> entry.key end)
    to_seed = Enum.reject(@builtin, &(&1.key in matched_keys))

    Enum.each(to_seed, fn entry ->
      caps = Enum.map_join(entry.capabilities, ",", &"'#{&1}'")

      execute("""
      INSERT INTO providers (id, name, base_url, key, source, dialect, capabilities, status, inserted_at, updated_at)
      VALUES (
        '#{Ecto.UUID.generate()}',
        '#{escape(entry.name)}',
        '#{entry.base_url}',
        '#{entry.key}',
        'builtin',
        '#{entry.dialect}',
        ARRAY[#{caps}]::varchar[],
        'active',
        now(),
        now()
      )
      """)
    end)

    length(to_seed)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp match_key(base_url) do
    case match_by_base_url(base_url) do
      nil -> nil
      entry -> entry.key
    end
  end

  # Raw provider rows as plain maps with atom keys (SELECT order is fixed),
  # independent of the current schema shape. `id::text` — a raw query
  # returns uuid as a 16-byte binary, which cannot be interpolated back
  # into SQL.
  defp fetch_providers do
    %{rows: rows} =
      Tokengate.Repo.query!(
        "SELECT id::text, name, base_url, embedding_base_url, inserted_at FROM providers"
      )

    Enum.map(rows, fn [id, name, base_url, embedding_base_url, inserted_at] ->
      %{
        id: id,
        name: name,
        base_url: base_url,
        embedding_base_url: embedding_base_url,
        inserted_at: inserted_at
      }
    end)
  end

  defp credential_count(provider_id) do
    %{rows: [[count]]} =
      Tokengate.Repo.query!(
        "SELECT count(*) FROM provider_credentials WHERE provider_id = '#{provider_id}'::uuid"
      )

    count
  end

  defp escape(value), do: String.replace(value, "'", "''")
end
