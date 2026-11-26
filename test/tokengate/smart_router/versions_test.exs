defmodule Tokengate.SmartRouter.VersionsTest do
  # `async: false` because every write path takes the transaction-scoped
  # advisory lock `smart_router_default_promotion`: in sandbox mode that lock
  # lives for the whole owning test, so two concurrent async cases calling
  # promote/toggle would queue on each other for no gain.
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.PartitionWorker
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter

  alias Tokengate.SmartRouter.{
    Config,
    Presets,
    Rule,
    SessionPin,
    ShadowEvaluation,
    UseCase,
    UseCaseModel,
    Versions
  }

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp model_fixture do
    {:ok, model} =
      Providers.create_model(%{
        "name" => "versions-model-#{System.unique_integer([:positive])}",
        "context_window" => 128_000
      })

    model
  end

  defp member_fixture do
    {:ok, group} = Accounts.create_group(%{"name" => "G #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "versions-log-#{System.unique_integer([:positive])}@example.com",
        "name" => "Versions Log",
        "password" => "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    member
  end

  defp use_case_fixture(config, attrs) do
    attrs =
      Map.merge(
        %{key: "case_#{System.unique_integer([:positive])}", name: "Caso"},
        attrs
      )
      |> Map.put(:router_config_id, config.id)

    %UseCase{}
    |> UseCase.changeset(attrs)
    |> Repo.insert!()
  end

  defp binding_fixture(use_case, model, attrs) do
    attrs =
      Map.merge(
        %{target_model_id: model.id, effort_tier: "medium", supports_tools: true, priority: 10},
        attrs
      )
      |> Map.put(:router_use_case_id, use_case.id)

    %UseCaseModel{}
    |> UseCaseModel.changeset(attrs)
    |> Repo.insert!()
  end

  defp rule_fixture(config, attrs) do
    attrs =
      Map.merge(
        %{
          name: "regla_#{System.unique_integer([:positive])}",
          action: "force_use_case",
          target_use_case_keys: ["fast"]
        },
        attrs
      )
      |> Map.put(:router_config_id, config.id)

    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert!()
  end

  # A Default with two specialties, three destinations, a fallback and a rule:
  # enough surface for a clone to be a meaningful test.
  defp seeded_default! do
    default =
      Config.ensure!()
      |> Config.changeset(%{
        enabled: true,
        policy: "quality_first",
        decision_timeout_ms: 500,
        description: "La que sirve tráfico"
      })
      |> Repo.update!()

    model_a = model_fixture()
    model_b = model_fixture()

    coding =
      use_case_fixture(default, %{
        key: "coding_implement",
        name: "Implementación",
        requires_tools: true,
        priority: 40
      })

    binding_fixture(coding, model_a, %{
      effort_tier: "high",
      effort_override: "high",
      min_confidence: Decimal.new("0.700")
    })

    binding_fixture(coding, model_b, %{effort_tier: "low"})

    fast =
      use_case_fixture(default, %{
        key: "fast",
        name: "Rápido",
        priority: 10,
        fallback_model_id: model_b.id
      })

    binding_fixture(fast, model_b, %{effort_tier: "any", priority: 5})

    rule_fixture(default, %{
      name: "conciliación",
      action: "force_use_case",
      target_use_case_keys: ["data_heavy_finance"],
      match_conditions: %{"min_tokens" => 1_000}
    })

    {default, %{model_a: model_a, model_b: model_b, coding: coding, fast: fast}}
  end

  defp find_use_case(config_id, key) do
    Repo.get_by!(UseCase, router_config_id: config_id, key: key)
  end

  defp bindings(use_case_id) do
    Repo.all(from b in UseCaseModel, where: b.router_use_case_id == ^use_case_id)
  end

  # ---------------------------------------------------------------------------
  # list_versions/1
  # ---------------------------------------------------------------------------

  describe "list_versions/1" do
    test "returns the Default first, then shadows, then the other candidates" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id, %{name: "Borrador"})
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})
      {:ok, _} = Versions.toggle_shadow!(shadow.id, true)

      assert [first, second | _] = Versions.list_versions()
      assert first.id == default.id
      assert second.id == shadow.id
      assert Enum.any?(Versions.list_versions(), &(&1.id == candidate.id))
    end

    test "hides archived versions unless include_archived: true" do
      {default, _} = seeded_default!()
      retired = Versions.clone_version!(default.id, %{name: "Retirada"})
      {:ok, archived} = Versions.archive_version!(retired.id)

      refute Enum.any?(Versions.list_versions(), &(&1.id == archived.id))
      assert Enum.any?(Versions.list_versions(include_archived: true), &(&1.id == archived.id))
    end

    test "get_default!/0 and get_version!/1 open one row each" do
      {default, _} = seeded_default!()

      assert Versions.get_default!().id == default.id
      assert Versions.get_version!(default.id).name == default.name
      assert_raise Ecto.NoResultsError, fn -> Versions.get_version!(Ecto.UUID.generate()) end
    end
  end

  # ---------------------------------------------------------------------------
  # create_version/1
  # ---------------------------------------------------------------------------

  describe "create_version/1" do
    test "creates a draft that is neither the Default nor a shadow" do
      {default, _} = seeded_default!()

      assert {:ok, version} = Versions.create_version(%{name: "Propuesta"})
      refute version.is_default
      refute version.shadow_enabled
      assert version.archived_at == nil
      assert Versions.get_default!().id == default.id
      assert Repo.aggregate(UseCase, :count) == 2
    end

    test "refuses a version with a blank name" do
      assert {:error, changeset} = Versions.create_version(%{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "ignores is_default / shadow_enabled from the attrs (a create is a draft)" do
      {default, _} = seeded_default!()

      assert {:ok, version} =
               Versions.create_version(%{
                 name: "Colada",
                 is_default: true,
                 shadow_enabled: true
               })

      refute version.is_default
      refute version.shadow_enabled
      assert Versions.get_default!().id == default.id
    end

    test "normalises blank description and model pointers to nil" do
      assert {:ok, version} =
               Versions.create_version(%{
                 name: "Normalizada",
                 description: "",
                 default_model_id: "",
                 decision_model_id: "",
                 baseline_model_id: ""
               })

      assert version.description == nil
      assert version.default_model_id == nil
      assert version.decision_model_id == nil
      assert version.baseline_model_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # clone_version!/2
  # ---------------------------------------------------------------------------

  describe "clone_version!/2" do
    test "clones the config, every use case, its destinations and the rules" do
      {default, %{model_a: model_a, model_b: model_b, coding: coding, fast: fast}} =
        seeded_default!()

      clone = Versions.clone_version!(default.id)

      refute clone.id == default.id
      refute clone.is_default
      refute clone.shadow_enabled
      assert clone.archived_at == nil
      assert clone.name == "#{default.name} (copy)"

      # Config content is copied verbatim.
      assert clone.enabled == default.enabled
      assert clone.policy == default.policy
      assert clone.decision_timeout_ms == default.decision_timeout_ms
      assert clone.description == default.description

      # Use cases: same keys, different rows, same knobs.
      clone_coding = find_use_case(clone.id, "coding_implement")
      clone_fast = find_use_case(clone.id, "fast")
      refute clone_coding.id == coding.id
      assert clone_coding.name == coding.name
      assert clone_coding.requires_tools
      assert clone_coding.priority == coding.priority

      # The per-use-case fallback survives the copy.
      assert clone_fast.fallback_model_id == model_b.id
      assert clone_fast.fallback_model_id == fast.fallback_model_id

      # Destinations: same (model, tier) pairs, new binding rows.
      original_pairs =
        coding.id
        |> bindings()
        |> Enum.map(&{&1.target_model_id, &1.effort_tier})
        |> Enum.sort()

      clone_pairs =
        clone_coding.id
        |> bindings()
        |> Enum.map(&{&1.target_model_id, &1.effort_tier})
        |> Enum.sort()

      assert clone_pairs == original_pairs

      clone_high =
        clone_coding.id
        |> bindings()
        |> Enum.find(&(&1.effort_tier == "high"))

      # Every destination field is preserved, including the assets that are
      # easy to forget (override, flags, priority).
      assert clone_high.target_model_id == model_a.id
      assert clone_high.effort_override == "high"
      assert Decimal.equal?(clone_high.min_confidence, Decimal.new("0.700"))
      assert clone_high.supports_tools
      assert clone_high.priority == 10

      # Rules: same name, new row.
      assert [%Rule{} = clone_rule] =
               Repo.all(from r in Rule, where: r.router_config_id == ^clone.id)

      assert clone_rule.name == "conciliación"
      assert clone_rule.match_conditions == %{"min_tokens" => 1_000}
      assert clone_rule.target_use_case_keys == ["data_heavy_finance"]
    end

    test "accepts overrides, including string keys" do
      {default, _} = seeded_default!()

      clone = Versions.clone_version!(default.id, %{"name" => "Candidata", "enabled" => false})
      assert clone.name == "Candidata"
      refute clone.enabled
      assert Versions.get_default!().enabled
    end

    test "the clone holds the same keys without colliding with the Default" do
      {default, _} = seeded_default!()

      clone = Versions.clone_version!(default.id)
      assert Repo.aggregate(UseCase, :count) == 4

      # Same key, same version => rejected by the per-version unique index.
      assert {:error, changeset} =
               %UseCase{}
               |> UseCase.changeset(%{
                 router_config_id: clone.id,
                 key: "fast",
                 name: "Duplicada"
               })
               |> Repo.insert()

      assert errors_on(changeset).key == ["has already been taken"]
    end

    test "is atomic: a failing copy leaves nothing behind" do
      {default, _} = seeded_default!()
      before = Repo.aggregate(Config, :count)

      assert_raise Ecto.InvalidChangesetError, fn ->
        Versions.clone_version!(default.id, %{name: ""})
      end

      assert Repo.aggregate(Config, :count) == before
      assert Repo.aggregate(UseCase, :count) == 2
    end

    test "never inherits Default/shadow/archived state, even from the overrides" do
      {default, _} = seeded_default!()
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})
      {:ok, _} = Versions.toggle_shadow!(shadow.id, true)
      {:ok, archived} = Versions.archive_version!(shadow.id)

      clone =
        Versions.clone_version!(archived.id, %{
          name: "Copia",
          is_default: true,
          shadow_enabled: true,
          archived_at: DateTime.utc_now()
        })

      refute clone.is_default
      refute clone.shadow_enabled
      assert clone.archived_at == nil
      assert Versions.get_default!().id == default.id
    end

    test "a blank description normalises to nil, so the clone shows no phantom diff" do
      {default, _} = seeded_default!()
      default = default |> Config.changeset(%{description: nil}) |> Repo.update!()
      SmartRouter.invalidate()

      clone = Versions.clone_version!(default.id, %{name: default.name, description: ""})

      assert clone.description == nil

      refute Enum.any?(
               Versions.diff_versions(default.id, clone.id).config_diffs,
               &(&1.field == :description)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # promote_to_default!/2
  # ---------------------------------------------------------------------------

  describe "promote_to_default!/2" do
    test "swaps is_default atomically and keeps exactly one Default" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id, %{name: "Candidata"})

      assert {:ok, promoted} = Versions.promote_to_default!(candidate.id)
      assert promoted.is_default
      refute promoted.shadow_enabled

      refute Repo.get!(Config, default.id).is_default
      assert Repo.aggregate(from(c in Config, where: c.is_default == true), :count) == 1
      assert Versions.get_default!().id == candidate.id
      assert Config.get().id == candidate.id

      # The outgoing Default stays as a candidate version.
      assert Repo.get!(Config, default.id).archived_at == nil
    end

    test "carries the outgoing Default's global enabled and baseline_model_id" do
      {default, %{model_a: baseline}} = seeded_default!()

      candidate =
        Versions.clone_version!(default.id, %{
          name: "Candidata",
          enabled: false,
          baseline_model_id: nil
        })

      assert default.enabled
      assert default.baseline_model_id == nil

      # Put a real baseline on the outgoing Default, then promote.
      default =
        default
        |> Config.changeset(%{baseline_model_id: baseline.id, enabled: true})
        |> Repo.update!()

      assert {:ok, promoted} = Versions.promote_to_default!(candidate.id)
      assert promoted.enabled
      assert promoted.baseline_model_id == baseline.id

      outgoing = Repo.get!(Config, default.id)
      refute outgoing.is_default
    end

    test "preserve_global: false lets the promoted version keep its own flags" do
      {default, %{model_a: baseline}} = seeded_default!()

      default =
        default
        |> Config.changeset(%{baseline_model_id: baseline.id, enabled: true})
        |> Repo.update!()

      candidate =
        Versions.clone_version!(default.id, %{
          name: "Candidata",
          enabled: false,
          baseline_model_id: nil
        })

      assert {:ok, promoted} =
               Versions.promote_to_default!(candidate.id, preserve_global: false)

      refute promoted.enabled
      assert promoted.baseline_model_id == nil
      assert Repo.get!(Config, default.id).enabled
    end

    test "refuses an archived version" do
      {default, _} = seeded_default!()
      retired = Versions.clone_version!(default.id, %{name: "Retirada"})
      {:ok, _} = Versions.archive_version!(retired.id)

      assert {:error, :archived_version} = Versions.promote_to_default!(retired.id)
      assert Versions.get_default!().id == default.id
    end

    test "promoting the current Default is a no-op" do
      {default, _} = seeded_default!()

      assert {:ok, promoted} = Versions.promote_to_default!(default.id)
      assert promoted.id == default.id
      assert promoted.is_default
    end

    test "drops the cached snapshot and every session pin" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id, %{name: "Candidata"})

      # Warm the snapshot with the old Default and pin a live conversation.
      assert SmartRouter.snapshot().config.id == default.id

      SessionPin.put("subject", "session", %{model_id: "stale"}, 60_000)
      assert %{model_id: "stale"} = SessionPin.get("subject", "session")

      assert {:ok, promoted} = Versions.promote_to_default!(candidate.id)

      assert SmartRouter.snapshot().config.id == promoted.id
      assert SessionPin.get("subject", "session") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # toggle_shadow!/3
  # ---------------------------------------------------------------------------

  describe "toggle_shadow!/3" do
    test "refuses to shadow the Default" do
      {default, _} = seeded_default!()

      assert {:error, :cannot_shadow_default} = Versions.toggle_shadow!(default.id, true)
      refute Versions.get_default!().shadow_enabled
    end

    test "enables a sampled shadow on a candidate" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id)

      assert {:ok, shadow} = Versions.toggle_shadow!(candidate.id, true, 25)
      assert shadow.shadow_enabled
      assert shadow.shadow_sample_pct == 25

      assert {:ok, off} = Versions.toggle_shadow!(shadow.id, false)
      refute off.shadow_enabled
      # Turning it off keeps the last sample percentage.
      assert off.shadow_sample_pct == 25
    end

    test "rejects an out-of-range sample" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id)

      for pct <- [0, 101] do
        assert {:error, changeset} = Versions.toggle_shadow!(candidate.id, true, pct)
        assert errors_on(changeset).shadow_sample_pct != []
      end

      refute Repo.get!(Config, candidate.id).shadow_enabled
    end

    test "refuses an archived version" do
      {default, _} = seeded_default!()
      retired = Versions.clone_version!(default.id)
      {:ok, _} = Versions.archive_version!(retired.id)

      assert {:error, :archived_version} = Versions.toggle_shadow!(retired.id, true)
    end
  end

  # ---------------------------------------------------------------------------
  # archive_version!/1 and unarchive_version!/1
  # ---------------------------------------------------------------------------

  describe "archive_version!/1" do
    test "refuses to archive the Default" do
      {default, _} = seeded_default!()

      assert {:error, :cannot_archive_default} = Versions.archive_version!(default.id)
      assert Versions.get_default!().id == default.id
    end

    test "archives a candidate and turns its shadow off" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id, %{name: "Candidata"})
      {:ok, shadow} = Versions.toggle_shadow!(candidate.id, true)

      assert {:ok, archived} = Versions.archive_version!(shadow.id)
      assert archived.archived_at
      refute archived.shadow_enabled

      assert {:ok, restored} = Versions.unarchive_version!(archived.id)
      assert restored.archived_at == nil
      refute restored.shadow_enabled
      refute restored.is_default
    end
  end

  # ---------------------------------------------------------------------------
  # Session pins
  # ---------------------------------------------------------------------------

  describe "session pins" do
    test "only promotion drops live pins; toggling and archiving keep them" do
      {default, _} = seeded_default!()
      candidate = Versions.clone_version!(default.id, %{name: "Candidata"})

      SessionPin.put("subject", "session", %{model_id: "live"}, 60_000)
      assert %{model_id: "live"} = SessionPin.get("subject", "session")

      # A shadow toggle and an archive change the candidate, never the serving
      # version: the pin still points at a Default destination.
      assert {:ok, _} = Versions.toggle_shadow!(candidate.id, true)
      assert %{model_id: "live"} = SessionPin.get("subject", "session")

      assert {:ok, _} = Versions.archive_version!(candidate.id)
      assert %{model_id: "live"} = SessionPin.get("subject", "session")

      assert {:ok, _} = Versions.unarchive_version!(candidate.id)
      assert %{model_id: "live"} = SessionPin.get("subject", "session")

      # Promotion moves the catalogue: the pin names the OLD version's
      # destinations and must go.
      assert {:ok, _} = Versions.promote_to_default!(candidate.id)
      assert SessionPin.get("subject", "session") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # diff_versions/2
  # ---------------------------------------------------------------------------

  describe "diff_versions/2" do
    test "a fresh clone is identical in every dimension" do
      {default, _} = seeded_default!()
      # Same name on purpose: the "(copy)" suffix is a real config difference.
      clone = Versions.clone_version!(default.id, %{name: default.name})

      assert %{config_diffs: [], use_case_diffs: [], rule_diffs: []} =
               Versions.diff_versions(default.id, clone.id)
    end

    test "reports config, use-case, destination and rule disagreements" do
      {default, _} = seeded_default!()
      clone = Versions.clone_version!(default.id, %{name: "Candidata"})

      # Config knob change.
      {:ok, clone} = clone |> Config.changeset(%{policy: "cost_first"}) |> Repo.update()

      # Use case knob change.
      clone_fast = find_use_case(clone.id, "fast")
      {:ok, _} = clone_fast |> UseCase.changeset(%{enabled: false}) |> Repo.update()

      # Destination removed (the low tier of coding_implement).
      clone_coding = find_use_case(clone.id, "coding_implement")
      low = clone_coding.id |> bindings() |> Enum.find(&(&1.effort_tier == "low"))
      {:ok, _} = Repo.delete(low)

      # Rule removed and another added.
      conciliation = Repo.get_by!(Rule, router_config_id: clone.id, name: "conciliación")
      {:ok, _} = Repo.delete(conciliation)

      rule_fixture(clone, %{
        name: "nueva",
        action: "restrict_use_cases",
        target_use_case_keys: ["fast"]
      })

      diff = Versions.diff_versions(default.id, clone.id)

      assert %{field: :policy, left: "quality_first", right: "cost_first"} =
               Enum.find(diff.config_diffs, &(&1.field == :policy))

      fast_diff = Enum.find(diff.use_case_diffs, &(&1.key == "fast"))
      assert fast_diff.status == :changed

      assert %{field: :enabled, left: true, right: false} =
               Enum.find(fast_diff.fields, &(&1.field == :enabled))

      coding_diff = Enum.find(diff.use_case_diffs, &(&1.key == "coding_implement"))
      assert coding_diff.status == :changed
      assert [%{effort_tier: "low"}] = coding_diff.destinations.removed
      assert coding_diff.destinations.added == []
      assert coding_diff.destinations.changed == []

      assert Enum.any?(
               diff.rule_diffs,
               &(&1.name == "conciliación" and &1.status == :only_in_left)
             )

      assert Enum.any?(diff.rule_diffs, &(&1.name == "nueva" and &1.status == :only_in_right))
    end

    test "a use case that exists only on one side is reported as such" do
      {default, _} = seeded_default!()
      clone = Versions.clone_version!(default.id)

      use_case_fixture(clone, %{key: "vision_extraction", name: "Extracción"})

      assert [%{key: "vision_extraction", status: :only_in_right, fields: []}] =
               Versions.diff_versions(default.id, clone.id).use_case_diffs
    end
  end

  # ---------------------------------------------------------------------------
  # Version-scoped schema invariants
  # ---------------------------------------------------------------------------

  describe "version scoping" do
    test "a use case or rule built without a version belongs to the Default" do
      default = Config.ensure!()

      {:ok, use_case} =
        %UseCase{}
        |> UseCase.changeset(%{key: "fast", name: "Rápido"})
        |> Repo.insert()

      {:ok, rule} =
        %Rule{}
        |> Rule.changeset(%{
          name: "legacy",
          action: "force_use_case",
          target_use_case_keys: ["fast"]
        })
        |> Repo.insert()

      assert use_case.router_config_id == default.id
      assert rule.router_config_id == default.id
    end

    test "router_config_id is NOT NULL in the database" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Postgrex.Error, ~r/null value in column "router_config_id"/, fn ->
        Repo.insert_all(UseCase, [
          %{id: Ecto.UUID.generate(), key: "x", name: "X", inserted_at: now, updated_at: now}
        ])
      end
    end

    test "deleting a version deletes its use cases, destinations and rules" do
      {default, _} = seeded_default!()
      clone = Versions.clone_version!(default.id)

      clone_coding = find_use_case(clone.id, "coding_implement")
      assert length(bindings(clone_coding.id)) == 2

      assert {:ok, _} = Repo.delete(clone)

      refute Repo.get(UseCase, clone_coding.id)
      assert bindings(clone_coding.id) == []
      assert Repo.all(from r in Rule, where: r.router_config_id == ^clone.id) == []
      # The Default is untouched.
      assert Repo.get_by!(UseCase, router_config_id: default.id, key: "coding_implement")
    end

    test "the shadow sample is bounded and a version cannot be Default and shadow" do
      config = Config.ensure!()

      refute Config.changeset(config, %{shadow_sample_pct: 0}).valid?
      refute Config.changeset(config, %{shadow_sample_pct: 101}).valid?
      assert Config.changeset(config, %{shadow_sample_pct: 100}).valid?

      changeset = Config.changeset(config, %{is_default: true, shadow_enabled: true})
      refute changeset.valid?
      assert errors_on(changeset).shadow_enabled != []
    end

    test "the database rejects a Default that is also a shadow" do
      {default, _} = seeded_default!()

      assert_raise Postgrex.Error, ~r/router_configs_default_not_shadow_check/, fn ->
        Repo.query!(
          "UPDATE router_configs SET shadow_enabled = true WHERE id = $1::uuid",
          [Ecto.UUID.dump!(default.id)]
        )
      end
    end

    test "the changeset turns an archived Default into a field error" do
      {default, _} = seeded_default!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:error, changeset} =
               default |> Config.changeset(%{archived_at: now}) |> Repo.update()

      assert errors_on(changeset).is_default != []
      assert Repo.get!(Config, default.id).archived_at == nil
    end

    test "the database rejects an archived Default" do
      {default, _} = seeded_default!()

      assert_raise Postgrex.Error, ~r/router_configs_default_not_archived_check/, fn ->
        Repo.query!(
          "UPDATE router_configs SET archived_at = now() WHERE id = $1::uuid",
          [Ecto.UUID.dump!(default.id)]
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Presets
  # ---------------------------------------------------------------------------

  describe "Presets.ensure_all!/1" do
    test "seeds the Default by default and any version when given its id" do
      default = Config.ensure!()
      assert %{inserted: 12, existing: 0} = Presets.ensure_all!()

      assert Repo.aggregate(from(u in UseCase, where: u.router_config_id == ^default.id), :count) ==
               12

      # The clone already carries the Default's twelve use cases: seeding it
      # again must not duplicate them.
      clone = Versions.clone_version!(default.id)
      assert Repo.aggregate(UseCase, :count) == 24

      assert %{inserted: 0, existing: 12} = Presets.ensure_all!(clone.id)
      assert Repo.aggregate(UseCase, :count) == 24

      assert Repo.aggregate(from(u in UseCase, where: u.router_config_id == ^clone.id), :count) ==
               12

      # Re-seeding either version is a no-op.
      assert %{inserted: 0, existing: 12} = Presets.ensure_all!()
      assert %{inserted: 0, existing: 12} = Presets.ensure_all!(clone.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Shadow evaluations
  # ---------------------------------------------------------------------------

  describe "ShadowEvaluation" do
    defp shadow_evaluation_fixture(config, attrs \\ %{}) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %ShadowEvaluation{}
      |> ShadowEvaluation.changeset(
        Map.merge(
          %{
            request_log_id: Ecto.UUID.generate(),
            request_inserted_at: now,
            shadow_config_id: config.id,
            shadow_config_name: config.name,
            default_use_case_key: "fast",
            default_model_name: "model-a",
            use_case_key: "writing",
            model_name: "model-b",
            decision_source: "classifier",
            decision_ms: 120,
            estimated_served_cost_usd: Decimal.new("0.001200")
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    test "persists the comparison and defaults inserted_at" do
      {default, _} = seeded_default!()
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})

      evaluation = shadow_evaluation_fixture(shadow, %{default_config_id: default.id})

      assert evaluation.inserted_at
      assert evaluation.shadow_config_id == shadow.id
      refute evaluation.matches_default_model
      assert Decimal.equal?(evaluation.estimated_served_cost_usd, Decimal.new("0.001200"))
    end

    test "requires the log pair, the version and its name" do
      changeset = ShadowEvaluation.changeset(%ShadowEvaluation{}, %{})
      refute changeset.valid?

      assert %{request_log_id: [_], request_inserted_at: [_], shadow_config_id: [_]} =
               errors_on(changeset)
    end

    test "deleting the version deletes its evaluations" do
      {default, _} = seeded_default!()
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})
      evaluation = shadow_evaluation_fixture(shadow)

      assert {:ok, _} = Repo.delete(shadow)
      refute Repo.get(ShadowEvaluation, evaluation.id)
    end
  end

  describe "PartitionWorker.prune_shadow_evaluations/1" do
    test "deletes evaluations past retention and keeps the fresh ones" do
      {default, _} = seeded_default!()
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})
      retention = PartitionWorker.retention_days()

      old_at =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-(retention + 5) * 86_400, :second)

      expired = shadow_evaluation_fixture(shadow, %{inserted_at: old_at})
      fresh = shadow_evaluation_fixture(shadow)

      assert {:ok, %{deleted: 1}} = PartitionWorker.prune_shadow_evaluations(retention)

      refute Repo.get(ShadowEvaluation, expired.id)
      assert Repo.get(ShadowEvaluation, fresh.id)

      # Idempotent: nothing left to delete.
      assert {:ok, %{deleted: 0}} = PartitionWorker.prune_shadow_evaluations(retention)
    end

    test "prunes everything older than the cutoff when the window is short" do
      {default, _} = seeded_default!()
      shadow = Versions.clone_version!(default.id, %{name: "Sombra"})

      ten_days_ago =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-10 * 86_400, :second)

      expired = shadow_evaluation_fixture(shadow, %{inserted_at: ten_days_ago})

      assert {:ok, %{deleted: 1}} = PartitionWorker.prune_shadow_evaluations(7)
      refute Repo.get(ShadowEvaluation, expired.id)
    end
  end

  # ---------------------------------------------------------------------------
  # request_logs integration
  # ---------------------------------------------------------------------------

  describe "request_logs" do
    test "persists the deciding version and accepts a pre-generated id" do
      member = member_fixture()
      default = Config.ensure!()
      id = Ecto.UUID.generate()
      inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, log} =
               Logs.log_request(%{
                 id: id,
                 inserted_at: inserted_at,
                 subject_type: "user",
                 group_member_id: member.id,
                 model_requested: "router",
                 routed_via_router: true,
                 router_config_id: default.id,
                 status_code: 200
               })

      assert log.id == id
      reloaded = Repo.get_by!(RequestLog, id: id, inserted_at: inserted_at)
      assert reloaded.router_config_id == default.id
    end

    test "WriteWorker keeps the pre-generated id and the deciding version" do
      member = member_fixture()
      default = Config.ensure!()
      id = Ecto.UUID.generate()

      args = %{
        "id" => id,
        "inserted_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "subject_type" => "user",
        "group_member_id" => member.id,
        "model_requested" => "router",
        "routed_via_router" => true,
        "router_config_id" => default.id,
        "status_code" => 200
      }

      # Force the enqueue-failure branch: the fallback insert reads the SAME
      # attrs, which is what proves the worker path persists both fields.
      insert_fun = fn _job -> {:error, :pool_timeout} end

      assert :ok =
               Tokengate.Logs.WriteWorker.enqueue(
                 Tokengate.Logs.WriteWorker.new(args),
                 %{model_id: nil, provider_id: nil, status: 200},
                 insert_fun
               )

      row = Repo.get_by!(RequestLog, id: id)
      assert row.router_config_id == default.id
      assert row.routed_via_router
    end
  end

  # ---------------------------------------------------------------------------
  # Reversibility of the migration
  # ---------------------------------------------------------------------------

  describe "migration artifacts" do
    test "the versioning artifacts exist and down/0 is defined" do
      [{module, _binary} | _] =
        "priv/repo/migrations/*_add_smart_router_versions_and_shadow.exs"
        |> Path.wildcard()
        |> Enum.map(&Code.compile_file/1)
        |> List.flatten()

      # A real `down/0` (not a `change/0` guess) is what makes `mix ecto.rollback`
      # possible; the SQL it emits is exercised against the dev and test
      # databases in the delivery check.
      assert function_exported?(module, :up, 0)
      assert function_exported?(module, :down, 0)

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
         WHERE indexname = 'router_configs_single_default_idx'
        """)

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "WHERE (is_default = true)"

      %{rows: rows} =
        Repo.query!("""
        SELECT conname FROM pg_constraint
         WHERE conrelid = 'router_configs'::regclass AND contype = 'c'
        """)

      names = List.flatten(rows)
      assert "router_configs_shadow_sample_pct_check" in names
      assert "router_configs_default_not_shadow_check" in names
      refute "router_configs_singleton_check" in names

      for table <- ~w(router_use_cases router_rules) do
        %{rows: [[nullable]]} =
          Repo.query!(
            """
            SELECT is_nullable FROM information_schema.columns
             WHERE table_name = $1 AND column_name = 'router_config_id'
            """,
            [table]
          )

        assert nullable == "NO"
      end

      assert column_exists?("request_logs", "router_config_id")
      assert column_exists?("router_shadow_evaluations", "request_inserted_at")
    end
  end

  defp column_exists?(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1 FROM information_schema.columns
         WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    rows != []
  end
end
