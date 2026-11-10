defmodule Tokengate.Repo.Migrations.AddEffortPolicyToModels do
  @moduledoc """
  Operator effort policy per logical model (`models` is already the home of
  operator-owned per-model configuration):

  * `effort_default` — substitutes a client `reasoning_effort` of
    `none`/`minimal` (the values strict upstreams reject with 400).
  * `effort_override` — replaces the client's reasoning effort
    unconditionally, whatever it sends (even nothing).

  Both are nullable strings over `low`/`medium`/`high`; NULL = no-op, so the
  gateway's behaviour for unconfigured models is byte-identical to before.
  """

  use Ecto.Migration

  def change do
    alter table(:models) do
      add :effort_default, :string
      add :effort_override, :string
    end
  end
end
