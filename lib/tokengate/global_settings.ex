defmodule Tokengate.GlobalSettings do
  @moduledoc """
  Singleton row storing instance-wide settings that apply to every request.

  Currently holds the **global daily spending cap** — the kill-switch (layer 2
  of the budget model) that rejects all requests once the total daily spend
  across every member and credential reaches the configured amount (USD).
  Resets at 00:00 UTC.

  `nil` daily_max_spend_usd means unlimited (default).

  ## Hot path

  `get_daily_cap/0` is read on EVERY proxied request before reserving budget,
  so the value lives in `:persistent_term` (a singleton that only changes when
  an admin saves it). `update/2` erases the cached entry, so the next read goes
  to the DB and repopulates it. The public API is unchanged.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Tokengate.Repo

  # Fixed primary key of the single singleton row (seeded in a migration).
  @singleton_id 1

  # Key for the `:persistent_term` copy of the daily cap. GlobalSettings is a
  # singleton, so a single entry covers every caller.
  @daily_cap_key {__MODULE__, :daily_cap}

  schema "global_settings" do
    field :daily_max_spend_usd, :decimal

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:daily_max_spend_usd])
    |> validate_number(:daily_max_spend_usd, greater_than_or_equal_to: 0)
  end

  @doc "Returns the singleton global settings row."
  def get!(id \\ @singleton_id), do: Repo.get!(__MODULE__, id)

  @doc """
  Returns the global daily spending cap (nil = unlimited).

  Served from `:persistent_term` on the request path: the first read after
  boot (or after an `update/2`) hits Postgres, every subsequent one is a
  lock-free term read. A non-singleton id (tests, tooling) always reads the
  row.
  """
  def get_daily_cap(id \\ @singleton_id) do
    if id == @singleton_id do
      case :persistent_term.get(@daily_cap_key, :missing) do
        :missing ->
          cap = get!(id).daily_max_spend_usd
          :persistent_term.put(@daily_cap_key, cap)
          cap

        cap ->
          cap
      end
    else
      get!(id).daily_max_spend_usd
    end
  end

  @doc """
  Updates the singleton global settings row.

  A successful write invalidates the hot-path cache so the next
  `get_daily_cap/0` observes the new cap immediately.
  """
  def update(attrs, id \\ @singleton_id) do
    result =
      get!(id)
      |> changeset(attrs)
      |> Repo.update()

    with {:ok, _} <- result do
      if id == @singleton_id, do: :persistent_term.erase(@daily_cap_key)
      result
    end
  end

  @doc """
  Drops the cached daily cap.

  Test support (the `:persistent_term` is VM-global and survives the Ecto
  sandbox rollback) — production invalidation happens inside `update/2`.
  """
  def reset_cache do
    :persistent_term.erase(@daily_cap_key)
    :ok
  end
end
