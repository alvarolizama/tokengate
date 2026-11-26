defmodule Tokengate.SmartRouter.PresetsTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Presets
  alias Tokengate.SmartRouter.UseCase
  alias Tokengate.SmartRouter.UseCaseModel

  @expected_keys ~w(fast writing presentations coding_implement coding_arch_debug
    data_heavy_finance research computer_use modeling_3d vision_extraction
    structured_etl translation_i18n)

  describe "preset catalog" do
    test "ships the twelve specialties in priority order" do
      assert Presets.keys() == @expected_keys
      assert length(Presets.all()) == 12
    end

    test "every preset is a valid use case and carries its knobs" do
      for preset <- Presets.all() do
        changeset = UseCase.changeset(%UseCase{}, preset)

        assert changeset.valid?,
               "preset #{preset.key} is invalid: #{inspect(errors_on(changeset))}"

        assert is_binary(preset.name) and preset.name != ""
        assert is_binary(preset.description) and preset.description != ""
        assert is_list(preset.tags) and preset.tags != []
        assert is_boolean(preset.requires_tools)
        assert is_boolean(preset.critical_accuracy)
        assert is_boolean(preset.allow_downgrade)
        assert is_boolean(preset.pin_session)
        assert is_boolean(preset.compact_json)
        assert is_integer(preset.priority)
      end
    end

    test "the prompt-saving and accuracy knobs are actually differentiated" do
      by_key = Map.new(Presets.all(), &{&1.key, &1})

      # Críticos: no se degradan y no se fijan a la sesión como un chatbot cualquiera.
      assert by_key["coding_arch_debug"].critical_accuracy
      refute by_key["coding_arch_debug"].allow_downgrade
      assert by_key["data_heavy_finance"].critical_accuracy
      refute by_key["data_heavy_finance"].allow_downgrade

      # Visión obligatoria en los que trabajan sobre imágenes.
      assert by_key["computer_use"].requires_vision
      assert by_key["vision_extraction"].requires_vision
      refute by_key["writing"].requires_vision

      # Lotes sin sesión: ETL/extracción no arrastran historial ni pin.
      refute by_key["structured_etl"].pin_session

      assert by_key["structured_etl"].max_history_turns <
               by_key["coding_arch_debug"].max_history_turns

      # Compactar JSON donde el shape de salida es el contrato.
      assert by_key["structured_etl"].compact_json
      assert by_key["vision_extraction"].compact_json
    end
  end

  describe "ensure_all!/0" do
    test "seeds every preset exactly once" do
      assert %{inserted: 12, existing: 0} = Presets.ensure_all!()

      assert Repo.aggregate(UseCase, :count) == 12

      assert Enum.sort(Repo.all(from u in UseCase, select: u.key)) == Enum.sort(@expected_keys)
    end

    test "is idempotent and never overwrites operator edits" do
      Presets.ensure_all!()

      fast = Repo.get_by!(UseCase, key: "fast")

      {:ok, edited} =
        fast
        |> UseCase.changeset(%{name: "Rápido (editado)", max_history_turns: 3, enabled: false})
        |> Repo.update()

      assert %{inserted: 0, existing: 12} = Presets.ensure_all!()

      reloaded = Repo.get_by!(UseCase, key: "fast")
      assert reloaded.id == edited.id
      assert reloaded.name == "Rápido (editado)"
      assert reloaded.max_history_turns == 3
      refute reloaded.enabled

      # Ni una fila duplicada.
      assert Repo.aggregate(UseCase, :count) == 12
    end

    test "does not bind models: a fresh seed routes nowhere" do
      Presets.ensure_all!()

      assert Repo.aggregate(UseCaseModel, :count) == 0
    end
  end

  describe "UseCase.changeset/2" do
    test "requires a key and a name" do
      changeset = UseCase.changeset(%UseCase{}, %{})
      refute changeset.valid?
      assert %{key: [_], name: [_]} = errors_on(changeset)
    end

    test "the key is a lowercase slug" do
      for bad <- ["Fast", "coding-implement", "1fast", "fast path", ""] do
        refute UseCase.changeset(%UseCase{}, %{key: bad, name: "X"}).valid?,
               "expected #{inspect(bad)} to be rejected"
      end

      assert UseCase.changeset(%UseCase{}, %{key: "coding_implement_2", name: "X"}).valid?
    end

    test "the key is unique" do
      {:ok, use_case} = Repo.insert(UseCase.changeset(%UseCase{}, %{key: "fast", name: "Fast"}))

      assert {:error, changeset} =
               Repo.insert(UseCase.changeset(%UseCase{}, %{key: "fast", name: "Otro"}))

      assert errors_on(changeset).key == ["has already been taken"]
      assert use_case.key == "fast"
    end

    test "the trim threshold is a percentage" do
      refute UseCase.changeset(%UseCase{}, %{
               key: "x",
               name: "X",
               stale_tool_trim_threshold_pct: 101
             }).valid?

      assert UseCase.changeset(%UseCase{}, %{
               key: "x",
               name: "X",
               stale_tool_trim_threshold_pct: 100
             }).valid?
    end
  end
end
