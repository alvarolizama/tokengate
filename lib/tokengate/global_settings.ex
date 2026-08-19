defmodule Tokengate.GlobalSettings do
  @moduledoc """
  Singleton row storing instance-wide settings that apply to every request.

  Currently holds the **global daily spending cap** — a kill-switch that
  rejects all requests once the total daily spend across every member and
  credential reaches the configured amount (USD). Resets at 00:00 UTC.

  `nil` daily_max_spend_usd means unlimited (default).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tokengate.Repo

  # Fixed primary key of the single singleton row (seeded in a migration).
  @singleton_id 1

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

  @doc "Returns the global daily spending cap (nil = unlimited)."
  def get_daily_cap(id \\ @singleton_id) do
    get!(id).daily_max_spend_usd
  end

  @doc "Updates the singleton global settings row."
  def update(attrs, id \\ @singleton_id) do
    get!(id)
    |> changeset(attrs)
    |> Repo.update()
  end
end
