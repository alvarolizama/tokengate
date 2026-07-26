defmodule Tokengate.Accounts.Organization do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :cost_tracking_mode, :string, default: "value"

    has_many :teams, Tokengate.Accounts.Team

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name slug cost_tracking_mode)a
  @required ~w(name slug)a

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> update_change(:slug, &slugify/1)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
  end

  defp slugify(nil), do: nil
  defp slugify(slug) when is_binary(slug), do: String.downcase(String.trim(slug))
end
