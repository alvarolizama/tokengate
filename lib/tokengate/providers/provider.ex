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
  @rerank_formats ~w(cohere dashscope)
  @embedding_formats ~w(openai dashscope)

  schema "providers" do
    field :name, :string
    # Base URL for the LLM (chat) surface. The adapter appends
    # /chat/completions to this.
    field :base_url, :string
    # Optional full-URL override for the embeddings endpoint. When nil, the
    # adapter appends /embeddings to base_url.
    field :embedding_base_url, :string
    # Payload/response format for embeddings: "openai" (passthrough) or
    # "dashscope" (native input.texts / output.embeddings).
    field :embedding_format, :string, default: "openai"
    # Optional full-URL override for the rerank endpoint. When nil, the
    # adapter appends /rerank to base_url.
    field :rerank_base_url, :string
    # Payload/response format for rerank: "cohere" (passthrough) or
    # "dashscope" (native output.results).
    field :rerank_format, :string, default: "cohere"
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
      :embedding_format,
      :rerank_base_url,
      :rerank_format,
      :status
    ])
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:embedding_format, @embedding_formats)
    |> validate_inclusion(:rerank_format, @rerank_formats)
    |> normalize_urls()
    |> unique_constraint(:name)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses

  @doc "List of valid rerank formats"
  def rerank_formats, do: @rerank_formats

  @doc "List of valid embedding formats"
  def embedding_formats, do: @embedding_formats

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
