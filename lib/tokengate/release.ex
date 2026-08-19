defmodule Tokengate.Release do
  @moduledoc """
  Release tasks invoked via `bin/tokengate eval` from the rel/overlays
  scripts (`bin/migrate`, `bin/setup`) and the container entrypoint.

    * `migrate/0` — run pending Ecto migrations.
    * `setup/0`   — idempotent first-run setup: create DB if missing →
      migrate → seed the admin user. Safe to invoke on every deploy.
    * `seed/0`    — run `priv/repo/seeds.exs` (creates the admin user;
      idempotent).

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
  Safe for prod: the seed only ensures the admin user exists
  (TOKENGATE_ADMIN_EMAIL / TOKENGATE_ADMIN_PASSWORD env vars).

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
  Run priv/repo/seeds.exs. Idempotent: only creates the admin user when
  it doesn't exist. Override credentials via TOKENGATE_ADMIN_EMAIL /
  TOKENGATE_ADMIN_PASSWORD.
  """
  def seed do
    load_config()
    seeds_file = Application.app_dir(@app, "priv/repo/seeds.exs")

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo -> Code.eval_file(seeds_file) end,
          timeout: @start_timeout
        )
    end
  end

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
