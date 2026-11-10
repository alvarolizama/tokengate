defmodule Tokengate.Providers.Model do
  @moduledoc """
  A model model is a logical model name that maps to one or more
  provider-backed models (model_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tokengate.Providers.Lab

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The full service surface of the gateway. Chat and embeddings route by
  # model_type; the three media services (stt, tts, image) persist their real
  # type too — `service_passthrough` passes it as the
  # routing capability, so a model registered as `stt` is only reachable from
  # the /audio/transcriptions endpoint (and vice versa). `decision` is
  # TypeSafe's System One surface: its PUBLIC endpoint is `/v1/decisions`
  # (the OpenAI Decisions shape, translated for System One providers), with
  # the chat path kept for compatibility — its own type so pickers and
  # grants distinguish it.
  @model_types ~w(llm embedding decision stt tts image)

  # Operator effort policy vocabulary (`models.effort_default` /
  # `effort_override`): the levels every mainstream upstream documents for
  # `reasoning_effort`. nil = no-op.
  @effort_levels ~w(low medium high)

  # Hero icon names, e.g. "hero-beaker" — same shape and same validation as a
  # lab's fallback icon.
  @icon_format ~r/^hero-[a-z0-9-]+$/

  # What the model card falls back to when it has neither a lab mark nor an
  # icon of its own (`ModelsLive` is the only reader today).
  @default_icon "hero-cpu-chip"

  schema "models" do
    field :name, :string
    field :context_window, :integer
    field :model_type, :string, default: "llm"
    field :guard_rails, :string
    field :prompt_cache_enabled, :boolean, default: false
    # Operator effort policy (chat models). `effort_default` substitutes a
    # client reasoning effort of `none`/`minimal` (values strict upstreams
    # reject with 400); `effort_override` replaces the client's effort
    # unconditionally. nil = no-op: the body travels as the client sent it.
    field :effort_default, :string
    field :effort_override, :string
    field :lazy_cleanup_enabled, :boolean, default: false
    field :pinned, :boolean, default: false
    # The lab that built the model, from the id's prefix (soft link to
    # `labs.key`: a lab row is not required for the model to exist).
    field :lab_key, :string
    # Fallback hero icon (`hero-cpu-chip`) for a model with no lab — or with a
    # lab that carries no mark. Operator-owned, like the lab's own `icon`; a
    # linked lab always wins in the UI.
    field :icon, :string

    has_many :model_providers, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :name,
      :context_window,
      :model_type,
      :guard_rails,
      :prompt_cache_enabled,
      :effort_default,
      :effort_override,
      :lazy_cleanup_enabled,
      :pinned,
      :lab_key,
      :icon
    ])
    |> validate_required([:name, :context_window])
    |> validate_inclusion(:model_type, @model_types)
    |> validate_inclusion(:effort_default, @effort_levels)
    |> validate_inclusion(:effort_override, @effort_levels)
    |> validate_format(:icon, @icon_format,
      message: "must be a hero icon name, e.g. hero-cpu-chip"
    )
    |> normalize_icon()
    |> normalize_effort_policy()
    |> unique_constraint(:name)
  end

  @doc "Valid reasoning effort levels for the operator policy"
  def effort_levels, do: @effort_levels

  @doc "List of valid model types"
  def model_types, do: @model_types

  @doc "The generic glyph of a model with no mark of its own (`hero-cpu-chip`)."
  def default_icon, do: @default_icon

  @doc """
  The mark to render next to a model: its lab's mark when the lab is linked and
  known, else the model's own `icon`, else the generic one.

  `labs_by_key` is a `%{lab_key => %Lab{}}` index, so the caller resolves the
  soft link once instead of a query per row. A `lab_key` whose lab row does not
  exist (the link is soft) is not an error: the model falls back to its own
  icon.

      iex> lab = %Tokengate.Providers.Lab{key: "openai", logo_url: "https://x/o.svg"}
      iex> Tokengate.Providers.Model.mark(%Tokengate.Providers.Model{lab_key: "openai"}, %{"openai" => lab})
      {:logo, "https://x/o.svg"}

      iex> Tokengate.Providers.Model.mark(%Tokengate.Providers.Model{icon: "hero-fire"}, %{})
      {:icon, "hero-fire"}

      iex> Tokengate.Providers.Model.mark(%Tokengate.Providers.Model{}, %{})
      {:icon, "hero-cpu-chip"}
  """
  @spec mark(%__MODULE__{}, map() | nil) :: {:logo, String.t()} | {:icon, String.t()}
  def mark(%__MODULE__{} = model, labs_by_key) do
    case Map.get(labs_by_key || %{}, model.lab_key) do
      %Lab{} = lab -> Lab.mark(lab)
      _ -> {:icon, model.icon || @default_icon}
    end
  end

  # An empty icon means "no fallback chosen": store nil, so "unset" has exactly
  # one representation and the UI can fall back to the default (same rule as
  # `Lab.normalize_icon/1`).
  defp normalize_icon(changeset) do
    case get_change(changeset, :icon) do
      nil -> changeset
      "" -> put_change(changeset, :icon, nil)
      icon -> put_change(changeset, :icon, String.trim(icon))
    end
  end

  # An empty effort policy means "not configured": store nil, so "unset" has
  # exactly one representation (the form's select prompt submits ""). Same
  # rule as `normalize_icon/1`.
  defp normalize_effort_policy(changeset) do
    for field <- [:effort_default, :effort_override], reduce: changeset do
      cs ->
        case get_change(cs, field) do
          "" -> put_change(cs, field, nil)
          value when is_binary(value) -> put_change(cs, field, String.trim(value))
          _ -> cs
        end
    end
  end
end
