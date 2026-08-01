defmodule Tokengate.Accounts.ServiceSupervisor do
  @moduledoc """
  Join table: a user (non-admin) who supervises a service with read-only access.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_supervisors" do
    belongs_to :service, Tokengate.Accounts.Service
    belongs_to :user, Tokengate.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(supervisor, attrs) do
    supervisor
    |> cast(attrs, [:service_id, :user_id])
    |> validate_required([:service_id, :user_id])
    |> unique_constraint([:service_id, :user_id])
  end
end
