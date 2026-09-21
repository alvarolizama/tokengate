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
    * `rollup_backfill/1` — rebuild the hourly metrics rollup from
      `request_logs` over a window (repair path, NOT part of the boot; see
      the function doc for the env vars and the container invocation).

  All migration/seed/rollback work is wrapped in `Ecto.Migrator.with_repo/2`
  — during `bin/tokengate eval` the full supervision tree (including the
  Repo) is not started. `create/0` talks to the adapter directly via
  `storage_up/1` and does not need the Repo started.
  """

  require Logger

  alias Tokengate.Metrics.Rollup.HourlyAggregate

  @app :tokengate
  @start_timeout 30_000
  # Same 90 days the RollupWorker prunes at: a rollup older than that is
  # dropped anyway, so there is nothing beyond it to rebuild.
  @default_rollup_backfill_days 90

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

  @doc """
  Rebuilds the hourly metrics rollup (`request_metrics_hourly`) from
  `request_logs` over a window: the repair path after a rollup written by a
  buggy version, a manual rewrite of `request_logs`, or a fresh instance.

  Deliberately NOT part of `setup/0`: the worker keeps the last 3 hours fresh
  and every day of history is its own transaction, so this can run for a long
  time and belongs to a one-off invocation, not to the boot.

      bin/rollup-backfill                                  # últimos 90 días
      ROLLUP_BACKFILL_DAYS=7 bin/rollup-backfill           # últimos 7 días
      ROLLUP_BACKFILL_FROM=2026-09-01 bin/rollup-backfill  # desde una fecha

  In a container: `docker exec <container> bin/rollup-backfill`, or as a
  one-off run with the entrypoint overridden —
  `docker run --rm --entrypoint /app/bin/rollup-backfill <image>` (same DB env
  vars as the app). `bin/tokengate eval Tokengate.Release.rollup_backfill`
  works too: that is what the wrapper calls.

  Env vars: `ROLLUP_BACKFILL_FROM` (`YYYY-MM-DD` = 00:00 UTC, or ISO8601 with
  offset), `ROLLUP_BACKFILL_TO` (default: now), `ROLLUP_BACKFILL_DAYS`
  (default: #{@default_rollup_backfill_days} — the rollup retention) used when
  `ROLLUP_BACKFILL_FROM` is absent. Explicit `opts` (`:from` / `:to` / `:days`)
  win over the environment; that is what `mix tokengate.rollup.backfill`
  passes.

  Safe to re-run: each UTC day is deleted and re-aggregated inside its own
  transaction, so a crash resumes where it stopped. Returns
  `%{days: n, rows: buckets}`.
  """
  @spec rollup_backfill(keyword()) :: %{days: non_neg_integer(), rows: non_neg_integer()}
  def rollup_backfill(opts \\ []) do
    load_config()

    from =
      Keyword.get(opts, :from) || env_datetime("ROLLUP_BACKFILL_FROM") ||
        default_backfill_from(opts)

    to =
      Keyword.get(opts, :to) || env_datetime("ROLLUP_BACKFILL_TO") ||
        DateTime.truncate(DateTime.utc_now(), :second)

    Logger.info(
      "[release] rollup backfill #{DateTime.to_iso8601(from)} → #{DateTime.to_iso8601(to)}"
    )

    results =
      for repo <- repos() do
        # `with_repo/3` devuelve `{:ok, resultado_de_la_fun, apps}` y
        # `HourlyAggregate.backfill/2` devuelve `{:ok, %{days:, rows:}}`.
        {:ok, {:ok, result}, _apps} =
          Ecto.Migrator.with_repo(repo, fn _repo -> HourlyAggregate.backfill(from, to) end)

        Logger.info("[release] rollup backfill: #{result.days} días, #{result.rows} buckets")

        result
      end

    List.last(results)
  end

  defp default_backfill_from(opts) do
    days =
      Keyword.get(opts, :days) || env_int("ROLLUP_BACKFILL_DAYS") || @default_rollup_backfill_days

    Date.utc_today()
    |> Date.add(-days)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp env_datetime(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> parse_datetime!(name, value)
    end
  end

  @doc """
  Accepts a `YYYY-MM-DD` date (read as 00:00 UTC) or an ISO8601 datetime, or
  raises. Public so the `mix tokengate.rollup.backfill` task parses `--from` /
  `--to` exactly like the release env vars do.
  """
  @spec parse_datetime!(String.t(), String.t()) :: DateTime.t()
  def parse_datetime!(name, value) do
    with {:error, _} <- DateTime.from_iso8601(value) do
      case Date.from_iso8601(value) do
        {:ok, date} ->
          DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

        {:error, _} ->
          raise ArgumentError, "#{name}=#{inspect(value)} no es una fecha ISO8601 válida"
      end
    else
      {:ok, dt, _offset} -> DateTime.shift_zone!(dt, "Etc/UTC")
    end
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {days, ""} -> days
          _ -> raise ArgumentError, "#{name}=#{inspect(value)} no es un entero"
        end
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
