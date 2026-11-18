defmodule Tokengate.ProdSeedTest do
  @moduledoc """
  El seed de producción (`priv/repo/seeds_prod.exs`) es lo que
  `Tokengate.Release.setup/0` evalúa en cada arranque de contenedor
  (`docker/entrypoint.sh`). Tiene que crear el admin y NADA más.

  Regresión que esto fija: `Release.seed/0` apuntaba a `priv/repo/seeds.exs`, el
  dataset de desarrollo, así que cada deploy sembraba en prod
  `dev@tokengate.local` / `tester@tokengate.local` (contraseña pública en este
  repo), el grupo `devs`/`qa`, el servicio `ci-bot`, modelos, credenciales
  placeholder y API keys activas.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts.{ApiKey, Group, GroupMember, Service, User}
  alias Tokengate.Credits.Topup
  alias Tokengate.Providers.{Credential, Model}
  alias Tokengate.Repo

  @admin_email "prod-admin@example.com"
  @admin_password "s3cr3t-de-prod-123456"

  # Todo lo que crea el seed de desarrollo. Nada de esto puede aparecer acá.
  @demo_emails ~w(dev@tokengate.local tester@tokengate.local)
  @demo_groups ~w(devs qa)
  @demo_services ~w(ci-bot)
  @demo_models ~w(gpt-5-nano glm-5.2 text-embedding qwen3-tts qwen3-reranker-8b)

  setup do
    previous = %{
      "TOKENGATE_ADMIN_EMAIL" => System.get_env("TOKENGATE_ADMIN_EMAIL"),
      "TOKENGATE_ADMIN_PASSWORD" => System.get_env("TOKENGATE_ADMIN_PASSWORD")
    }

    System.put_env("TOKENGATE_ADMIN_EMAIL", @admin_email)
    System.put_env("TOKENGATE_ADMIN_PASSWORD", @admin_password)

    on_exit(fn ->
      for {var, value} <- previous do
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end
    end)

    :ok
  end

  defp eval_prod_seed, do: Code.eval_file(Tokengate.Release.seeds_file())

  test "Release.seed/0 evalúa el seed de producción, no el dataset de desarrollo" do
    path = Tokengate.Release.seeds_file()

    assert Path.basename(path) == "seeds_prod.exs"
    assert File.exists?(path)
  end

  test "crea el admin y nada más" do
    eval_prod_seed()

    admin = Repo.get_by(User, email: @admin_email)
    assert admin.global_role == "admin"
    assert Repo.aggregate(User, :count) == 1

    for email <- @demo_emails, do: assert(Repo.get_by(User, email: email) == nil)
    for name <- @demo_groups, do: assert(Repo.get_by(Group, name: name) == nil)
    for name <- @demo_services, do: assert(Repo.get_by(Service, name: name) == nil)
    for name <- @demo_models, do: assert(Repo.get_by(Model, name: name) == nil)

    refute Repo.exists?(GroupMember)
    assert Repo.aggregate(ApiKey, :count) == 0
    assert Repo.aggregate(Credential, :count) == 0
    assert Repo.aggregate(Topup, :count) == 0
  end

  test "es idempotente: correrlo dos veces no duplica el admin" do
    eval_prod_seed()
    eval_prod_seed()

    assert Repo.aggregate(User, :count) == 1
  end

  test "sin TOKENGATE_ADMIN_PASSWORD no crea ningún usuario" do
    System.delete_env("TOKENGATE_ADMIN_PASSWORD")

    eval_prod_seed()

    assert Repo.aggregate(User, :count) == 0
  end

  # oMLX es un host LOCAL de rerank: su fila es custom y vive en el seed de
  # DESARROLLO (con el prerequisito de tener un reranker instalado). Nunca es
  # builtin (F70): el catálogo de código se materializa con identidad bloqueada
  # en cada instancia y una `base_url` de 127.0.0.1 quedaría muerta en
  # cualquier otro host. El seed de producción no puede crearlo.
  test "el lane local de rerank (oMLX) no es builtin ni lo siembra producción" do
    alias Tokengate.Providers.{Catalog, Provider, ModelProvider}

    refute "omlx" in Catalog.code_provider_keys()

    eval_prod_seed()

    assert Repo.get_by(Provider, key: "omlx") == nil
    assert Repo.get_by(Provider, name: "oMLX (local)") == nil
    assert Repo.get_by(Model, name: "qwen3-reranker-8b") == nil
    assert Repo.aggregate(ModelProvider, :count) == 0

    # El tipo SÍ es servible (la ruta existe): lo que no existe es un builtin
    # que lo sirva desde código.
    assert "rerank" in Catalog.served_capabilities()
  end
end
