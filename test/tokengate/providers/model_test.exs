defmodule Tokengate.Providers.ModelTest do
  use ExUnit.Case, async: true

  alias Tokengate.Providers.{Lab, Model}

  describe "mark/2" do
    test "el lab vinculado manda: su logo, si no su icono, si no el default del lab" do
      logo = %Lab{key: "openai", logo_url: "https://x/o.svg"}

      assert Model.mark(%Model{lab_key: "openai"}, %{"openai" => logo}) ==
               {:logo, "https://x/o.svg"}

      icon = %Lab{key: "openai", icon: "hero-fire"}
      assert Model.mark(%Model{lab_key: "openai"}, %{"openai" => icon}) == {:icon, "hero-fire"}

      bare = %Lab{key: "openai"}
      assert Model.mark(%Model{lab_key: "openai"}, %{"openai" => bare}) == {:icon, "hero-beaker"}
    end

    test "sin lab conocido cae al icono propio y, si tampoco hay, al genérico" do
      assert Model.mark(%Model{lab_key: "fantasma", icon: "hero-bolt"}, %{"otro" => %Lab{}}) ==
               {:icon, "hero-bolt"}

      assert Model.mark(%Model{}, %{}) == {:icon, Model.default_icon()}
      assert Model.mark(%Model{}, nil) == {:icon, Model.default_icon()}
    end
  end

  describe "changeset — icono" do
    test "vacío se guarda como nil: una sola representación de «sin icono»" do
      changeset = Model.changeset(%Model{}, %{name: "m", context_window: 1, icon: ""})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :icon) == nil
    end

    test "rechaza algo que no es un hero icon" do
      changeset = Model.changeset(%Model{}, %{name: "m", context_window: 1, icon: "beaker"})

      refute changeset.valid?

      assert {"must be a hero icon name, e.g. hero-cpu-chip", _} =
               changeset.errors[:icon]
    end
  end
end
