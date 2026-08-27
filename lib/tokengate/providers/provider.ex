defmodule Tokengate.Providers.Provider do
  @moduledoc """
  A provider is an upstream LLM API (OpenAI, Anthropic, etc.) that
  TokenGate routes requests to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  schema "providers" do
    field :name, :string
    # Base URL for the LLM (chat) surface. The adapter appends
    # /chat/completions to this.
    field :base_url, :string
    # Optional full-URL override for the embeddings endpoint. When nil, the
    # adapter appends /embeddings to base_url.
    field :embedding_base_url, :string
    # Optional full-URL override for the rerank endpoint. When nil, the
    # adapter appends /rerank to base_url.
    field :rerank_base_url, :string
    field :status, :string, default: "active"

    has_many :credentials, Tokengate.Providers.Credential

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :base_url,
      :embedding_base_url,
      :rerank_base_url,
      :status
    ])
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> normalize_urls()
    |> unique_constraint(:name)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses

  # Normalize empty-string URL overrides to nil so the adapter falls back to
  # the base_url-derived path.
  defp normalize_urls(changeset) do
    changeset
    |> normalize_blank(:embedding_base_url)
    |> normalize_blank(:rerank_base_url)
  end

  defp normalize_blank(changeset, field) do
    case get_field(changeset, field) do
      "" -> put_change(changeset, field, nil)
      _ -> changeset
    end
  end
end
