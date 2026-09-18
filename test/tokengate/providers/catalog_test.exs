defmodule Tokengate.Providers.CatalogTest do
  @moduledoc """
  Catalog (models.dev mirror + code customizations) + dispatch + builtin-lock
  coverage.
  """
  use Tokengate.DataCase, async: true

  import Ecto.Query
  alias Tokengate.Providers.{Catalog, CatalogProvider, CatalogSync, Provider}
  alias Tokengate.Proxy.ProviderAdapter

  setup do
    # The boot sync runs outside the test sandbox (and can be cut short), so
    # make the mirror + materialization deterministic for this test process.
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    :ok = CatalogSync.sync()
    :ok
  end

  describe "vendored snapshot" do
    test "every provider has a unique id and the display fields the UI needs" do
      entries = Catalog.snapshot()
      assert length(entries) >= 200

      keys = Enum.map(entries, & &1.key)
      assert length(keys) == length(Enum.uniq(keys))

      Enum.each(entries, fn entry ->
        # models.dev reaches some providers without publishing a base URL
        # (cloud-specific auth), publishes a few as account-scoped templates,
        # and a couple are local servers — so http is legitimate too.
        case entry.base_url do
          nil ->
            :ok

          url ->
            assert String.starts_with?(url, ["https://", "http://"]) or
                     String.contains?(url, "${")
        end

        assert is_binary(entry.name) and entry.name != ""
        assert is_binary(entry.logo_url) and entry.logo_url =~ "/logos/"
        assert is_binary(entry.doc_url) and entry.doc_url != ""
      end)
    end

    test "no provider id collides with the modal's own DOM ids" do
      # models.dev really publishes a provider whose id is "modal": with the row
      # id built as "catalog-#{key}" it collided with the modal container's
      # id="catalog-modal" (LiveView raises on duplicate ids). The rendered ids
      # are namespaced, so this pins the scheme rather than the incident.
      reserved =
        ~w(catalog-modal catalog-search catalog-results catalog-empty catalog-count
           new-custom-provider-btn add-provider-btn close-catalog-modal)

      keys = Enum.map(Catalog.snapshot(), & &1.key)
      assert "modal" in keys

      rendered_ids =
        Enum.flat_map(keys, fn key ->
          ["catalog-row-#{key}", "activate-catalog-#{key}", "docs-#{key}"]
        end)

      assert Enum.filter(rendered_ids, &(&1 in reserved)) == []
    end

    test "snapshot ids are URL-safe (they are the key used by the worker)" do
      Enum.each(Catalog.snapshot(), fn entry ->
        assert entry.key =~ ~r/^[a-z0-9][a-z0-9._-]*$/
      end)
    end
  end

  describe "code customizations" do
    test "capabilities are declared per provider, in code" do
      assert Catalog.capabilities("fireworks-ai") == ["llm", "embedding"]
      assert Catalog.capabilities("anthropic") == []
      assert Catalog.capabilities(nil) == []
    end

    test "the vocabulary covers the modalities the catalog publishes" do
      assert Catalog.capabilities() ==
               ~w(llm embedding rerank stt tts image video)
    end

    test "billing is a code label (models.dev publishes none)" do
      assert Catalog.billing("zai-coding-plan") == "subscription"
      assert Catalog.billing("kimi-for-coding") == "subscription"
      assert Catalog.billing("alibaba-token-plan") == "subscription"
      assert Catalog.billing("opencode-go") == "subscription"

      # Pay-per-token is the absence of a label, not a stored string.
      assert Catalog.billing("openrouter") == nil
      assert Catalog.billing("nope") == nil
      assert Catalog.billing_modes() == ~w(subscription pay_per_token)
    end

    test "dialect resolves from npm, and a code customization wins over it" do
      # npm says Anthropic SDK; the gateway speaks the OpenAI-compatible
      # surface of that same base URL, so the customization pins it.
      assert Catalog.dialect("kimi-for-coding") == {:ok, "openai"}

      assert Catalog.dialect(%{key: "x", npm: "@ai-sdk/openai-compatible"}) == {:ok, "openai"}

      assert Catalog.dialect(%{key: "x", npm: "@openrouter/ai-sdk-provider"}) ==
               {:ok, "openrouter"}

      assert {:error, reason} = Catalog.dialect(%{key: "x", npm: "@ai-sdk/anthropic"})
      assert reason =~ "@ai-sdk/anthropic"
    end

    test "supported?/1 needs both a base URL and a dialect" do
      ok = %{key: "x", base_url: "https://x.example.com/v1", npm: "@ai-sdk/openai-compatible"}
      assert Catalog.supported?(ok)
      assert Catalog.unsupported_reason(ok) == nil

      no_url = %{ok | base_url: nil}
      refute Catalog.supported?(no_url)
      assert Catalog.unsupported_reason(no_url) =~ "base URL"

      no_dialect = %{ok | npm: "@ai-sdk/google"}
      refute Catalog.supported?(no_dialect)
      assert Catalog.unsupported_reason(no_dialect) =~ "dialecto"

      refute Catalog.supported?(nil)
    end

    test "an account-scoped template is not a usable base URL" do
      templated = %{
        key: "snowflake-cortex",
        base_url: "https://${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com/api/v2/cortex/v1",
        npm: "@ai-sdk/openai-compatible"
      }

      refute Catalog.supported?(templated)
      assert Catalog.unsupported_reason(templated) =~ "template"
    end

    test "a code base_url override makes a row models.dev publishes without one usable" do
      # cerebras llega del catálogo con base_url NULL; su URL vive en la
      # customización de código. El gate de supported?/1 tiene que ver la URL
      # EFECTIVA, o el proveedor queda deshabilitado aunque el override exista.
      row = %{key: "cerebras", base_url: nil, npm: "@ai-sdk/cerebras"}

      assert Catalog.base_url(row) == "https://api.cerebras.ai/v1"
      assert Catalog.dialect(row) == {:ok, "openai"}
      assert Catalog.unsupported_reason(row) == nil
      assert Catalog.supported?(row)

      # Sin override sigue siendo inservible: el gate no se relaja.
      refute Catalog.supported?(%{key: "sin-url", base_url: nil, npm: "@ai-sdk/openai"})
    end

    test "base_url/1 trims the trailing slash and honours nothing else by default" do
      assert Catalog.base_url(%{key: "x", base_url: "https://x.example.com/v1/"}) ==
               "https://x.example.com/v1"

      assert Catalog.base_url(nil) == nil
    end

    test "a code-owned provider models.dev never publishes is usable from code alone" do
      # Surplus es el caso MÁS extremo que Cerebras: models.dev no publica su
      # fila en absoluto, así que no hay nada remoto que completar — ni base
      # URL, ni npm del que derivar el dialecto. Toda su identidad está en
      # código, y el gate de supported?/1 tiene que aceptarla.
      row = %{key: "surplus-intelligence", base_url: nil, npm: nil}

      assert Catalog.base_url(row) == "https://api.surplusintelligence.ai/v1"
      assert Catalog.dialect(row) == {:ok, "openai"}
      assert Catalog.unsupported_reason(row) == nil
      assert Catalog.supported?(row)
      assert Catalog.capabilities("surplus-intelligence") == ["llm", "embedding"]
    end

    test "the video path of a code-owned provider overrides the generic default" do
      # El default genérico de video es `/videos`, que en Surplus responde 404:
      # su generación vive en `/video/generations`. Es exactamente el caso que
      # existe para `:paths` en la customización.
      assert Catalog.path_suffix("surplus-intelligence",
               service: :video,
               default: "/videos"
             ) == "/video/generations"

      # Los servicios que SÍ coinciden con el default no llevan override.
      assert Catalog.path_suffix("surplus-intelligence",
               service: :chat,
               default: "/chat/completions"
             ) == "/chat/completions"

      assert Catalog.path_suffix("surplus-intelligence",
               service: :embeddings,
               default: "/embeddings"
             ) == "/embeddings"
    end

    test "code_providers/0 carries the fields the mirror stores" do
      assert [%{key: "surplus-intelligence"} = entry] = Catalog.code_providers()

      assert entry.name == "Surplus Intelligence"
      assert entry.base_url == "https://api.surplusintelligence.ai/v1"
      assert is_binary(entry.doc_url) and entry.doc_url != ""
      assert is_binary(entry.logo_url) and entry.logo_url != ""
      assert entry.status == "active"

      # Y las keys son consultables para que el refresh no las barra a stale.
      assert "surplus-intelligence" in Catalog.code_provider_keys()
    end

    test "path_suffix/2 defaults to the dialect path when no override exists" do
      assert Catalog.path_suffix("openrouter", service: :chat, default: "/chat/completions") ==
               "/chat/completions"

      assert Catalog.path_suffix(nil, service: :embeddings, default: "/embeddings") ==
               "/embeddings"
    end
  end

  describe "dispatch/1 by dialect" do
    test "resolves openrouter dialect" do
      assert ProviderAdapter.dispatch(%{dialect: "openrouter"}) ==
               Tokengate.Proxy.OpenRouterAdapter

      assert ProviderAdapter.dispatch(%{"dialect" => "openrouter"}) ==
               Tokengate.Proxy.OpenRouterAdapter
    end

    test "resolves openai dialect and defaults" do
      assert ProviderAdapter.dispatch(%{dialect: "openai"}) == Tokengate.Proxy.OpenAIAdapter
      assert ProviderAdapter.dispatch(%{name: "anything"}) == Tokengate.Proxy.OpenAIAdapter
      assert ProviderAdapter.dispatch(nil) == Tokengate.Proxy.OpenAIAdapter
    end
  end

  describe "provider changeset" do
    test "custom provider takes dialect and capabilities" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "my-relay",
          base_url: "https://relay.example.com/v1/",
          dialect: "openai",
          capabilities: ["llm", "embedding"]
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :base_url) == "https://relay.example.com/v1"
    end

    test "builtin identity fields are locked once source is builtin" do
      changeset =
        Provider.changeset(%Provider{source: "builtin", key: "openrouter"}, %{
          name: "hacked",
          base_url: "https://evil.example.com/v1",
          doc_url: "https://evil.example.com/docs",
          logo_url: "https://evil.example.com/logo.svg",
          dialect: "openai",
          capabilities: ["llm"],
          status: "disabled"
        })

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :name)
      refute Ecto.Changeset.get_change(changeset, :base_url)
      refute Ecto.Changeset.get_change(changeset, :doc_url)
      refute Ecto.Changeset.get_change(changeset, :logo_url)
      refute Ecto.Changeset.get_change(changeset, :dialect)
      refute Ecto.Changeset.get_change(changeset, :capabilities)
      assert Ecto.Changeset.get_change(changeset, :status) == "disabled"
    end

    test "invalid dialect and capabilities are rejected" do
      changeset =
        Provider.changeset(%Provider{}, %{
          name: "x",
          base_url: "https://x.com/v1",
          dialect: "cohere",
          capabilities: ["moderation"]
        })

      refute changeset.valid?
    end

    test "the per-service URL override columns are gone from the schema" do
      # Paths are code now: a row can no longer carry them.
      fields = Provider.__schema__(:fields)

      refute :chat_url in fields
      refute :models_url in fields
      refute :embeddings_url in fields
      assert :doc_url in fields
      assert :logo_url in fields
    end
  end

  describe "CatalogSync.sync/0" do
    test "materializes every supported mirror row and never touches customs" do
      {:ok, custom} =
        %Provider{}
        |> Provider.changeset(%{
          name: "my-own",
          base_url: "https://mine.example.com/v1",
          capabilities: ["llm"]
        })
        |> Tokengate.Repo.insert()

      :ok = CatalogSync.sync()

      supported_keys =
        Tokengate.Repo.all(CatalogProvider)
        |> Enum.filter(&Catalog.supported?/1)
        |> Enum.map(& &1.key)

      builtin_keys =
        Repo.all(from p in Provider, where: p.source == "builtin", select: p.key)

      # Every supported mirror row is materialized...
      assert supported_keys -- builtin_keys == []

      # ...and every builtin row has a mirror row behind it. (Rows
      # materialized under an older rule are KEPT — the sync never deletes —
      # so this is a subset check, not equality.)
      mirror_keys = Repo.all(from c in CatalogProvider, select: c.key)
      assert builtin_keys -- mirror_keys == []

      # Identity comes from the mirror, including docs/logo.
      fireworks = Tokengate.Repo.get_by!(Provider, key: "fireworks-ai")
      mirror = Tokengate.Repo.get!(CatalogProvider, "fireworks-ai")
      assert fireworks.base_url == Catalog.base_url(mirror)
      assert fireworks.doc_url == mirror.doc_url
      assert fireworks.logo_url == mirror.logo_url
      assert fireworks.capabilities == Catalog.capabilities("fireworks-ai")

      # The billing label is code, and a plan keeps it on a fresh database.
      assert fireworks.billing_type == "pay_per_token"
      plan = Tokengate.Repo.get_by!(Provider, key: "zai-coding-plan")
      assert plan.billing_type == "subscription"

      # Idempotent, and the custom row is untouched.
      builtin_count = Repo.aggregate(from(p in Provider, where: p.source == "builtin"), :count)
      :ok = CatalogSync.sync()

      mine = Tokengate.Repo.get_by!(Provider, name: "my-own")
      assert mine.id == custom.id
      assert mine.source == "custom"
      assert mine.dialect == "openai"

      assert Repo.aggregate(from(p in Provider, where: p.source == "builtin"), :count) ==
               builtin_count
    end

    test "skips providers the gateway cannot serve and stale ones" do
      # A supported provider whose mirror row went stale: the sync must not
      # (re)materialize it — the row is only kept while it is still upstream.
      mirror = Repo.get!(CatalogProvider, "deepseek")
      assert Catalog.supported?(mirror)
      Repo.delete_all(from p in Provider, where: p.key == "deepseek")

      {:ok, _} =
        mirror |> Ecto.Changeset.change(status: "stale") |> Repo.update()

      :ok = CatalogSync.sync()

      refute Repo.get_by(Provider, key: "deepseek")

      # And a provider we cannot speak to never gets a row at all.
      refute Repo.get_by(Provider, key: "anthropic")
    end
  end

  describe "CatalogSeed" do
    test "the mirror holds the whole snapshot exactly once" do
      # El mirror es el snapshot MÁS los proveedores code-owned: filas que
      # models.dev no publica y que existen solo en código, así que no pueden
      # venir del snapshot.
      assert Repo.aggregate(CatalogProvider, :count) ==
               Catalog.snapshot_size() + length(Catalog.code_provider_keys())
    end

    test "re-seeding is a no-op on rows that already exist" do
      assert Tokengate.Providers.CatalogSeed.seed() == 0

      assert Repo.aggregate(CatalogProvider, :count) ==
               Catalog.snapshot_size() + length(Catalog.code_provider_keys())
    end

    test "seed_if_empty is a no-op on a seeded mirror" do
      assert Tokengate.Providers.CatalogSeed.seed_if_empty() == 0
    end

    test "records the seed in the sync state" do
      # `seed_if_empty/0` y `sync/0` son no-ops cuando el mirror ya está
      # sembrado, y ninguno escribe el sync state: eso solo lo hace `seed/0`.
      # Sin forzar el seed, este test depende de qué otro test corrió antes.
      Tokengate.Providers.CatalogSeed.seed()
      state = Tokengate.Providers.catalog_sync_state()
      assert state.source in ["snapshot", "models.dev"]
      assert state.synced_at
    end
  end

  # ---------------------------------------------------------------------------
  # Labs — the mirror table and the context functions around it.
  # ---------------------------------------------------------------------------

  alias Tokengate.Providers
  alias Tokengate.Providers.{Lab, LabCatalog}

  describe "LabCatalog snapshot" do
    test "every lab has a unique key, a name and the models.dev logo" do
      entries = LabCatalog.snapshot()
      assert length(entries) >= 30

      keys = Enum.map(entries, & &1.key)
      assert length(keys) == length(Enum.uniq(keys))

      Enum.each(entries, fn entry ->
        assert entry.name in [nil, false] or (is_binary(entry.name) and entry.name != "")

        assert is_binary(entry.logo_url) and
                 entry.logo_url == "https://models.dev/logos/labs/#{entry.key}.svg"

        assert is_integer(entry.model_count) and entry.model_count >= 1

        # Verbatim upstream dates: day or month precision, never parsed.
        Enum.each([entry.last_released, entry.last_updated], fn date ->
          assert is_binary(date) and date =~ ~r/^\d{4}-\d{2}(-\d{2})?$/
        end)
      end)
    end

    test "keys are URL-safe (they are the primary key and the logo file stem)" do
      Enum.each(LabCatalog.snapshot(), fn entry ->
        assert entry.key =~ ~r/^[a-z0-9][a-z0-9._-]*$/
      end)
    end

    test "the labs table holds the whole snapshot exactly once" do
      assert Repo.aggregate(Lab, :count) == LabCatalog.snapshot_size()

      builtin =
        Repo.all(from l in Lab, where: l.source == "builtin", select: l.key)
        |> MapSet.new()

      snapshot_keys = LabCatalog.snapshot() |> Enum.map(& &1.key) |> MapSet.new()
      assert MapSet.equal?(builtin, snapshot_keys)
    end
  end

  describe "custom labs" do
    test "create, update and delete work, and the mark falls back to the icon" do
      {:ok, lab} =
        Providers.create_custom_lab(%{
          "name" => "Mi Laboratorio",
          "key" => "mi-lab",
          "icon" => "hero-beaker"
        })

      assert lab.source == "custom"
      assert LabCatalog.logo_url(lab.key) == "https://models.dev/logos/labs/mi-lab.svg"

      # No logo → the row's icon.
      assert lab |> Lab.changeset(%{"logo_url" => nil}) |> Repo.update!() |> Lab.mark() ==
               {:icon, "hero-beaker"}

      # Set logo → it wins over the icon.
      {:ok, lab} =
        lab
        |> Lab.changeset(%{"logo_url" => "https://cdn.example.com/mi-lab.png"})
        |> Repo.update()

      assert Lab.mark(lab) == {:logo, "https://cdn.example.com/mi-lab.png"}

      # Neither → the default icon (the logo persists: it is the primary mark).
      assert lab |> Lab.changeset(%{"icon" => ""}) |> Repo.update!() |> Lab.mark() ==
               {:logo, "https://cdn.example.com/mi-lab.png"}

      assert {:ok, lab} = Providers.delete_custom_lab(lab)
      refute Repo.get(Lab, "mi-lab")
    end

    test "the key is normalized and uniqueness is enforced with a friendly error" do
      # The format check wins when the raw key is invalid.
      assert {:error, _} =
               Providers.create_custom_lab(%{"name" => "Acme", "key" => "Acme Labs!"})

      assert {:ok, lab} = Providers.create_custom_lab(%{"name" => "Acme", "key" => "ACME-Labs"})

      assert lab.key == "acme-labs"

      assert {:error, changeset} =
               Providers.create_custom_lab(%{"name" => "Otro Acme", "key" => "acme-labs"})

      assert Enum.any?(
               changeset.errors,
               &match?({:key, {"has already been taken", _}}, &1)
             )
    end

    test "builtin labs reject edits and deletion" do
      builtin = Repo.get!(Lab, "openai")
      assert builtin.source == "builtin"

      assert {:error, changeset} = Providers.update_custom_lab(builtin, %{"name" => "hack"})

      assert Enum.any?(changeset.errors, &match?({:builtin, _}, &1))

      assert {:error, :builtin} = Providers.delete_custom_lab(builtin)
    end

    test "changeset validates the format, the source and the icon vocabulary" do
      assert %Ecto.Changeset{} =
               Lab.changeset(%Lab{}, %{"key" => "x", "name" => "X", "source" => "custom"})

      bad = Lab.changeset(%Lab{}, %{"key" => "Bad Key", "name" => "X", "source" => "custom"})
      refute bad.valid?

      bad_source =
        Lab.changeset(%Lab{}, %{"key" => "y", "name" => "Y", "source" => "hacked"})

      refute bad_source.valid?

      # Any `hero-*` name passes: the vocabulary is the whole Heroicons set,
      # and pinning it in code would drift from the asset pipeline.
      good_icon =
        Lab.changeset(%Lab{}, %{
          "key" => "z",
          "name" => "Z",
          "source" => "custom",
          "icon" => "hero-not-a-real-icon"
        })

      assert good_icon.valid?
    end

    test "list_labs filters by source, status and search" do
      {:ok, _} = Providers.create_custom_lab(%{"name" => "Quux Industries", "key" => "quux"})

      assert [_ | _] = Providers.list_labs(source: "custom")
      assert Providers.list_labs(search: "quux") |> Enum.map(& &1.key) == ["quux"]
      assert Providers.list_labs(search: "QUUX") |> Enum.map(& &1.key) == ["quux"]

      # A builtin example is always present (37 of them).
      assert Enum.any?(Providers.list_labs(source: "builtin"), &(&1.key == "openai"))

      quux = Repo.get!(Lab, "quux")

      quux
      |> Lab.changeset(%{"status" => "stale"})
      |> Repo.update!()

      assert Providers.list_labs(status: "stale") |> Enum.map(& &1.key) == ["quux"]
      assert Providers.list_labs(status: "active", search: "quux") == []
    end
  end

  describe "CatalogSeed labs" do
    test "seed_labs_if_empty is a no-op on a seeded lab table" do
      assert Tokengate.Providers.CatalogSeed.seed_labs_if_empty() == 0
      assert Repo.aggregate(Lab, :count) == LabCatalog.snapshot_size()
    end
  end

  describe "session_hint_fields/1" do
    test "every provider gets prompt_cache_key, and session_id is never hinted" do
      # `session_id` is OpenRouter's own body convention; the gateway stopped
      # sending it to anyone (OpenRouter's sticky key travels in the
      # x-session-id HEADER). So the narrowing override is unused today: every
      # key resolves to the same single field.
      assert Catalog.session_hint_fields("fireworks-ai") == ["prompt_cache_key"]
      assert Catalog.session_hint_fields("openrouter") == ["prompt_cache_key"]
      assert Catalog.session_hint_fields("moonshotai") == ["prompt_cache_key"]
    end

    test "unknown, custom and nil keys fall back to the same list" do
      assert Catalog.session_hint_fields("nope") == Catalog.default_session_hint_fields()
      assert Catalog.session_hint_fields(nil) == Catalog.default_session_hint_fields()
    end

    test "session_id is gone from the default hints" do
      refute "session_id" in Catalog.default_session_hint_fields()
      assert Catalog.default_session_hint_fields() == ["prompt_cache_key"]
    end
  end

  describe "omit_body_fields/1" do
    test "no provider declares a stripped field anymore" do
      # Fireworks used to declare `session_id` here because the gateway
      # injected it and Fireworks 400s on unknown body fields. Nothing injects
      # it now, so the entry went away with the behaviour.
      assert Catalog.omit_body_fields("fireworks-ai") == []
      assert Catalog.omit_body_fields("openrouter") == []
      assert Catalog.omit_body_fields(nil) == []
    end
  end
end
