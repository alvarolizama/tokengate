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
  @rerank_dialects ~w(cohere dashscope)

  schema "providers" do
    field :name, :string
    field :base_url, :string
    # Optional override for the rerank endpoint. When nil, the adapter
    # appends `/rerank` to `base_url` (Cohere format).
    field :rerank_base_url, :string
    # Payload/response format used for rerank. nil (no default) means
    # unselected — the changeset normalizer infers it from rerank_base_url.
    # Values: "cohere" (passthrough) or "dashscope" (native nested format).
    field :rerank_dialect, :string
    field :status, :string, default: "active"

    has_many :credentials, Tokengate.Providers.Credential

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :base_url, :rerank_base_url, :rerank_dialect, :status])
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:rerank_dialect, @rerank_dialects)
    |> normalize_rerank_dialect()
    |> unique_constraint(:name)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses

  @doc "List of valid rerank dialects"
  def rerank_dialects, do: @rerank_dialects

  # When no rerank_base_url is set, force the dialect to "cohere" — there
  # is nothing to translate if we're hitting the standard /rerank surface.
  # When a rerank_base_url IS set, default the dialect to "dashscope" only
  # if the user hasn't explicitly chosen one; the dashscope native endpoint
  # is the only non-Cohere surface we know today.
  defp normalize_rerank_dialect(changeset) do
    rerank_url = normalize_blank(get_field(changeset, :rerank_base_url))
    dialect_changed? = Ecto.Changeset.get_change(changeset, :rerank_dialect) != nil

    cond do
      is_nil(rerank_url) ->
        changeset |> put_change(:rerank_base_url, nil) |> put_change(:rerank_dialect, "cohere")

      not dialect_changed? ->
        # URL set but user didn't pick a dialect — default to dashscope.
        put_change(changeset, :rerank_dialect, "dashscope")

      true ->
        changeset
    end
  end

  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value
end
