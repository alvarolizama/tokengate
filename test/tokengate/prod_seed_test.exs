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
  @demo_models ~w(gpt-5-nano glm-5.2 text-embedding qwen3-rerank qwen3-tts wan-t2v)

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
end
