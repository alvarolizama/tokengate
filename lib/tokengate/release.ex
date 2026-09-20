defmodule Tokengate.Release do
  @moduledoc """
  Release tasks invoked via `bin/tokengate eval` from the rel/overlays
  scripts (`bin/migrate`, `bin/setup`) and the container entrypoint.

    * `migrate/0` — run pending Ecto migrations.
    * `setup/0`   — idempotent first-run setup: create DB if missing →
      migrate → seed the admin user. Safe to invoke on every deploy.
    * `seed/0`    — run `priv/repo/seeds_prod.exs` (admin bootstrap; requires
      TOKENGATE_ADMIN_PASSWORD, see below). NEVER point this at
      `priv/repo/seeds.exs`: that one is the development demo dataset.

  All migration/seed/rollback work is wrapped in `Ecto.Migrator.with_repo/2`
  — during `bin/tokengate eval` the full supervision tree (including the
  Repo) is not started. `create/0` talks to the adapter directly via
  `storage_up/1` and does not need the Repo started.
  """

  require Logger

  @app :tokengate
  @start_timeout 30_000

  @doc """
  Idempotent first-run setup: create DB if missing → migrate → seed admin.
  Safe for prod: the seed only ever ensures the admin user exists, and only
  when TOKENGATE_ADMIN_PASSWORD is set (otherwise nothing is created and the
  first admin comes from `/onboarding`).

  Single-instance only — with 2+ replicas racing on `storage_up`, switch
  the entrypoint to `bin/migrate` and create the DB once out-of-band.
  """
  def setup do
    load_config()
    create()
    migrate()
    seed()
    :ok
  end

  @doc "Create the database if it does not exist yet (idempotent)."
  def create do
    load_config()

    for repo <- repos() do
      case ensure_db_created(repo) do
        :ok -> :ok
        {:error, term} -> raise "failed to create db for #{inspect(repo)}: #{inspect(term)}"
      end
    end
  end

  @doc "Run pending migrations."
  def migrate do
    load_config()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_config()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Run priv/repo/seeds_prod.exs — the production seed. Idempotent, admin-only,
  and opt-in: the admin is created only when TOKENGATE_ADMIN_PASSWORD is set.
  Without it the instance keeps its users as they are and the first admin comes
  from the `/onboarding` page (see `TokengateWeb.OnboardingController`).

  The demo dataset lives in priv/repo/seeds.exs (dev) / demo_seeds.exs
  (mix ecto.demo) and must never run here: both create users with a password
  that is public in the repository.
  """
  def seed do
    load_config()
    seeds_file = seeds_file()

    if File.exists?(seeds_file) do
      for repo <- repos() do
        {:ok, _, _} =
          Ecto.Migrator.with_repo(
            repo,
            fn _repo -> Code.eval_file(seeds_file) end,
            timeout: @start_timeout
          )
      end
    else
      Logger.info("[release] no seed file at #{seeds_file}, nothing to seed")
      :ok
    end
  end

  @doc """
  Absolute path of the seed file `seed/0` evaluates.

  Public so a test can assert it resolves to the production seed and not the
  development one — that mix-up is what silently seeded demo users, groups,
  services, credentials and API keys into production.
  """
  @spec seeds_file() :: String.t()
  def seeds_file, do: Application.app_dir(@app, "priv/repo/seeds_prod.exs")

  defp ensure_db_created(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok ->
        Logger.info("[release] created database for #{inspect(repo)}")
        :ok

      # storage_up/1 creates the DB when missing and returns {:error,
      # :already_up} (tuple) when it already existed — confirmed against
      # the pinned ecto_sql 3.14. Older Ecto versions returned other
      # shapes, hence the legacy tuple clause below.
      {:error, :already_up} ->
        Logger.info("[release] database already exists for #{inspect(repo)}, skipping create")
        :ok

      {:error, {:already_up, _}} ->
        Logger.info("[release] database already exists for #{inspect(repo)}, skipping create")
        :ok

      {:error, term} ->
        {:error, term}
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Forces evaluation of config/runtime.exs (the config provider) so
  # repo.config() below resolves DATABASE_URL and friends.
  defp load_config do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
    _ = Application.get_all_env(@app)
    :ok
  end
end
