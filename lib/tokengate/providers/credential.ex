defmodule Tokengate.Providers.Credential do
  @moduledoc """
  API credentials for a provider. The `api_key_encrypted` field stores
  the key as-is for now; encryption-at-rest is a post-MVP concern.

  A credential is deliberately thin: an alias plus a secret. The operational
  limits (RPM, concurrency, per-user concurrency, receive timeout) belong to
  the provider (`Tokengate.Providers.Provider`) and are inherited by every
  credential attached to it.

  ## Field ownership

  The fields split into two trust levels, and only the first one is castable:

    * `@operator_fields` — `name` and `api_key_encrypted`. These are the two
      fields the admin form renders, and the only ones a submit can change.
    * programmatic fields — `provider_id`, `status`, `error_reason`,
      `error_message`, `error_at`. They are assigned explicitly from server
      code (`put_change/3`), never cast from params: a forged
      `credential[status]=active` (or a `provider_id` pointing at another
      provider) in an edit submit is not a change. The gateway disables a key
      by calling `Tokengate.Providers.update_credential/2` with atom-keyed
      attrs; a form submit is always string-keyed, so it cannot reach them.

  ## Status

    * `active`   – credential is eligible for routing.
    * `disabled` – manually disabled by an admin; excluded from routing.
    * `error`    – automatically disabled after a provider returned a
                   401/402/403 (auth or billing failure). Must be
                   reactivated manually from the dashboard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled error)

  # What an operator may edit through a form. Everything else is state.
  @operator_fields ~w(name api_key_encrypted)a

  # Lifecycle state: status plus the failure bookkeeping written when the
  # gateway disables a key and cleared when an admin reactivates it.
  @state_fields ~w(status error_reason error_message error_at)a

  schema "provider_credentials" do
    field :name, :string
    field :api_key_encrypted, :string
    field :status, :string, default: "active"
    field :error_reason, :string
    field :error_message, :string
    field :error_at, :utc_datetime

    belongs_to :provider, Tokengate.Providers.Provider
    has_many :model_providers, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, @operator_fields)
    |> put_provider_id(attrs)
    |> put_state(attrs)
    |> put_default_status()
    |> validate_required([:provider_id, :api_key_encrypted, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:provider_id)
  end

  @doc false
  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, @operator_fields)
    |> put_state(attrs)
    |> validate_required([:provider_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:provider_id)
  end

  @doc false
  def changeset(credential, attrs), do: create_changeset(credential, attrs)

  @doc "List of valid status values"
  def statuses, do: @statuses

  # A credential is created under a provider and never moves. The id comes from
  # the caller (the LiveView overwrites it with the page's provider, so the
  # hidden form field cannot point at another one) and stays out of the cast
  # allowlist, so no update can re-parent an existing key.
  defp put_provider_id(changeset, attrs) do
    provider_id = changeset.data.provider_id || explicit_param(attrs, :provider_id)

    if provider_id, do: put_change(changeset, :provider_id, provider_id), else: changeset
  end

  # Programmatic state is applied only when it arrives atom-keyed, which is how
  # gateway/admin code writes it (`%{status: "error"}`). Form params are
  # string-keyed, so an operator submit can never set them.
  defp put_state(changeset, attrs) do
    Enum.reduce(@state_fields, changeset, fn field, acc ->
      case explicit_attr(attrs, field) do
        {:ok, value} -> put_change(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp put_default_status(changeset) do
    if get_field(changeset, :status),
      do: changeset,
      else: put_change(changeset, :status, "active")
  end

  defp explicit_attr(attrs, field) when is_map(attrs), do: Map.fetch(attrs, field)
  defp explicit_attr(attrs, field) when is_list(attrs), do: Keyword.fetch(attrs, field)
  defp explicit_attr(_attrs, _field), do: :error

  # Creation accepts the provider under either key shape: gateway code passes
  # atoms and the admin LiveViews pass the form-shaped string, always rewritten
  # server-side to the provider of the page.
  defp explicit_param(attrs, field) when is_map(attrs) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end

  defp explicit_param(attrs, field) when is_list(attrs), do: Keyword.get(attrs, field)
  defp explicit_param(_attrs, _field), do: nil
end
