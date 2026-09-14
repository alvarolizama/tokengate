defmodule Tokengate.Providers.ModelProvider do
  @moduledoc """
  Joins a Model to a Credential, specifying the actual model name
  at the provider (`provider_model`), priority for routing, and
  enabled flag.

  Each row pins a specific credential — allowing multiple credentials
  from the same provider to serve the same model with different
  priorities for fallback.

  Billing lives on the provider (`providers.billing_type`, synced from the
  catalog for builtins, chosen at creation for customs). Routing tiers,
  cost calculation and sticky TTL defaults derive it via
  `billing_mode/1`. Per-provider pricing rows are gone; we trust the
  upstream to report what it actually charged.

  ## Exclusive scope

  A model_provider can be scoped to serve only specific consumers:

    * `nil` / `nil` — **global**: available to all group members with access.
    * `exclusive_to_group_member_id` set — **member exclusive**: only the
      specified group member sees this provider for the model.
    * `exclusive_to_group_id` set — **group exclusive**: only members of
      the specified group see this provider for the model.
    * `exclusive_to_service_id` set — **service exclusive**: only the
      specified service sees this provider for the model.

  The exclusive fields are mutually exclusive — you cannot set more than
  one. A credential can be used across different models, and can appear
  in multiple scope rows for the same model model (global, multiple
  group-exclusive, multiple member-exclusive) — each scope bucket has its
  own partial unique index preventing duplicates within that bucket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_modes ~w(pay_per_token included)
  @scopes ~w(global member group service)

  schema "model_providers" do
    field :provider_model, :string
    field :priority, :integer
    field :enabled, :boolean, default: true
    field :sticky_ttl_ms, :integer
    # Manual pricing fallback (USD per 1M tokens). Used when the upstream
    # doesn't report a cost (e.g. LiteLLM streaming). NULL = not set.
    field :input_cost_per_million, :decimal
    field :output_cost_per_million, :decimal
    field :cache_cost_per_million, :decimal
    # Virtual mirror of `sticky_ttl_ms` in seconds — exposed to the LiveView
    # form so operators can type `900` instead of `900_000`. Synced by
    # `sync_sticky_ttl_fields/1` before saving.
    field :sticky_ttl_seconds, :integer, virtual: true
    # Explicit Anthropic-style cache_control injection on the stable system
    # prefix. Off by default: only upstreams that honor cache_control
    # breakpoints (Anthropic, z.ai's OpenAI-compatible endpoint, OpenRouter
    # passthrough) benefit; elsewhere it's dead payload weight.
    field :cache_control_enabled, :boolean, default: false
    # Per-upstream request overrides (defaults are no-ops):
    #   * extra_body — JSON merged into the upstream request body (e.g.
    #     Fireworks' `{"service_tier": "priority"}` serving-path opt-in).
    #   * omit_body_fields — keys stripped from the upstream body (e.g.
    #     Fireworks 400s on the OpenRouter-style `session_id` hint).
    #   * omit_headers — forwarded headers NOT sent to this upstream.
    #     Never applies to authorization / content-type.
    field :extra_body, :map, default: %{}
    field :omit_body_fields, {:array, :string}, default: []
    field :omit_headers, {:array, :string}, default: []
    # Form fields for the per-upstream overrides. The LiveView form submits
    # free text (JSON string for extra_body, comma-separated lists for the
    # omit fields); these virtual fields mirror the stored ones the same
    # way sticky_ttl_seconds mirrors sticky_ttl_ms. Programmatic writes may
    # set the real fields directly.
    field :extra_body_json, :string, virtual: true
    # Fireworks' serving-path opt-in checkbox; mirrors extra_body["service_tier"].
    # Only rendered for fireworks-backed model_providers in the admin form.
    field :service_tier_priority, :boolean, virtual: true, default: false
    field :omit_body_fields_csv, :string, virtual: true
    field :omit_headers_csv, :string, virtual: true
    field :scope, :string, virtual: true, default: "global"

    belongs_to :model, Tokengate.Providers.Model
    belongs_to :credential, Tokengate.Providers.Credential
    belongs_to :exclusive_to_group_member, Tokengate.Accounts.GroupMember
    belongs_to :exclusive_to_group, Tokengate.Accounts.Group
    belongs_to :exclusive_to_service, Tokengate.Accounts.Service

    timestamps(type: :utc_datetime)
  end

  # Gateway-owned payload keys an operator override must never touch:
  # model mapping, passthrough body and usage accounting depend on them.
  @protected_body_keys ["model", "messages", "stream_options"]

  @doc false
  def changeset(model_provider, attrs) do
    model_provider
    |> cast(attrs, [
      :model_id,
      :credential_id,
      :provider_model,
      :priority,
      :enabled,
      :sticky_ttl_ms,
      :sticky_ttl_seconds,
      :cache_control_enabled,
      :extra_body,
      :omit_body_fields,
      :omit_headers,
      :extra_body_json,
      :service_tier_priority,
      :omit_body_fields_csv,
      :omit_headers_csv,
      :input_cost_per_million,
      :output_cost_per_million,
      :cache_cost_per_million,
      :exclusive_to_group_member_id,
      :exclusive_to_group_id,
      :exclusive_to_service_id
    ])
    |> validate_required([:model_id, :credential_id, :provider_model, :enabled])
    # 0 is the floor: -1 is reserved at runtime for exclusive providers
    # (Router.inject_exclusive_priority/1), so a configured negative priority
    # on a global row would outrank an exclusive one.
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:sticky_ttl_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 24 * 60 * 60 * 1000
    )
    |> validate_number(:sticky_ttl_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 24 * 60 * 60
    )
    |> sync_sticky_ttl_fields()
    |> sync_override_fields()
    |> validate_exclusive_scope()
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:exclusive_to_group_member_id)
    |> foreign_key_constraint(:exclusive_to_group_id)
    |> foreign_key_constraint(:exclusive_to_service_id)
    # Three partial unique indexes replace the old single composite index,
    # allowing the same credential to serve multiple scope buckets (global +
    # group-exclusive + member-exclusive) for the same model model.
    |> unique_constraint(:credential_id,
      name: :model_providers_global_credential_unique_index,
      message: "esta credencial ya es global para este modelo"
    )
    |> unique_constraint(:credential_id,
      name: :model_providers_group_exclusive_credential_unique_index,
      message: "esta credencial ya es exclusiva para este grupo y modelo"
    )
    |> unique_constraint(:credential_id,
      name: :model_providers_member_exclusive_credential_unique_index,
      message: "esta credencial ya es exclusiva para este usuario y modelo"
    )
    |> sync_scope_field()
  end

  @doc "List of valid billing modes (derived from the provider surface)"
  def billing_modes, do: @billing_modes

  @doc """
  Effective billing mode for a model_provider, derived from its
  credential's provider: a `subscription` provider maps to `"included"`
  (cost $0, top routing tier); anything else is `"pay_per_token"`.

  Handles not-loaded associations defensively (returns
  `"pay_per_token"`), though production paths always preload
  `credential: :provider`.
  """
  @spec billing_mode(map()) :: String.t()
  def billing_mode(%__MODULE__{} = mp) do
    case mp do
      %__MODULE__{credential: %{provider: %{billing_type: "subscription"}}} -> "included"
      _ -> "pay_per_token"
    end
  end

  @doc "List of valid scopes"
  def scopes, do: @scopes

  # -------------------------------------------------------------------
  # Validations
  # -------------------------------------------------------------------

  # Sync the virtual form fields into the stored ones. JSON/csv parsing
  # errors surface as changeset errors on the virtual field so they render
  # next to the input that produced them.
  defp sync_override_fields(changeset) do
    changeset
    |> sync_extra_body()
    # Header names are case-insensitive (normalized to lowercase); JSON
    # body keys are case-sensitive and kept as typed.
    |> sync_omit_list(:omit_body_fields_csv, :omit_body_fields, false)
    |> sync_omit_list(:omit_headers_csv, :omit_headers, true)
    |> sync_service_tier_priority()
  end

  # `service_tier: "priority"` is Fireworks' serving-path opt-in (higher
  # reliability during peak periods, priced at a premium). Exposed as a
  # checkbox that mirrors `extra_body["service_tier"]` so operators don't
  # hand-write JSON. The checkbox only rewrites the key it owns — a
  # hand-written extra_body JSON still wins when both are submitted (the
  # raw-JSON path runs first and this pass only touches the key when the
  # checkbox param is present).
  defp sync_service_tier_priority(changeset) do
    case param_submitted?(changeset, :service_tier_priority) do
      checked when checked in [true, "true", "on"] ->
        put_change(changeset, :extra_body, service_tier_merge(changeset, "priority"))

      # Absent param (programmatic update) leaves extra_body untouched;
      # a submitted-but-unchecked checkbox drops the key.
      :not_submitted ->
        changeset

      _unchecked ->
        put_change(changeset, :extra_body, service_tier_drop(changeset))
    end
  end

  defp service_tier_merge(changeset, tier) do
    (get_field(changeset, :extra_body) || %{})
    |> Map.put("service_tier", tier)
  end

  defp service_tier_drop(changeset) do
    (get_field(changeset, :extra_body) || %{})
    |> Map.delete("service_tier")
  end

  defp sync_extra_body(changeset) do
    case param_submitted?(changeset, :extra_body_json) do
      :not_submitted ->
        changeset

      submitted ->
        case json_extra_body(submitted) do
          {:ok, map} ->
            case Enum.find(Map.keys(map), &(&1 in @protected_body_keys)) do
              nil -> put_change(changeset, :extra_body, map)
              key -> add_error(changeset, :extra_body_json, "no se puede sobrescribir \"#{key}\"")
            end

          {:error, reason} ->
            add_error(changeset, :extra_body_json, "JSON inválido: #{reason}")
        end
    end
  end

  # cast/3 converts submitted "" to nil for string fields, so emptiness is
  # indistinguishable from absence via get_field/2. The raw params keep the
  # distinction: absent key = programmatic update that must not touch the
  # stored value; present-but-empty = the form field was cleared.
  defp param_submitted?(changeset, field) do
    string_key = Atom.to_string(field)
    params = changeset.params

    cond do
      Map.has_key?(params, field) -> Map.get(params, field)
      Map.has_key?(params, string_key) -> Map.get(params, string_key)
      true -> :not_submitted
    end
  end

  defp json_extra_body(json) when is_binary(json) do
    if String.trim(json) == "" do
      {:ok, %{}}
    else
      parse_json_object(json)
    end
  end

  defp json_extra_body(nil), do: {:ok, %{}}

  defp json_extra_body(other) do
    # A map arriving through extra_body_json means a programmatic caller
    # passed the map directly — accept it (JSON round-trip safe).
    if is_map(other) and not Map.has_key?(other, :__struct__) do
      {:ok, other}
    else
      {:error, "se esperaba un objeto"}
    end
  end

  defp parse_json_object(json) do
    case Jason.decode(String.trim(json)) do
      {:ok, %{} = map} ->
        # Reject arrays decoded as maps with integer keys is unnecessary —
        # Jason decodes arrays to lists. A bare list or scalar is invalid.
        {:ok, map}

      {:ok, _other} ->
        {:error, "se esperaba un objeto"}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, Exception.message(e)}
    end
  end

  @reserved_headers ["authorization", "content-type"]

  defp sync_omit_list(changeset, csv_field, stored_field, downcase?) do
    case param_submitted?(changeset, csv_field) do
      :not_submitted ->
        changeset

      submitted when is_binary(submitted) ->
        items =
          submitted
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(fn item -> if downcase?, do: String.downcase(item), else: item end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        cond do
          stored_field == :omit_body_fields and Enum.any?(items, &(&1 in @protected_body_keys)) ->
            blocked = Enum.find(items, &(&1 in @protected_body_keys))

            add_error(changeset, csv_field, "no se puede omitir \"#{blocked}\"")

          true ->
            case Enum.find(items, &(&1 in @reserved_headers)) do
              nil ->
                put_change(changeset, stored_field, items)

              reserved ->
                add_error(changeset, csv_field, "no se puede omitir \"#{reserved}\"")
            end
        end

      other when is_list(other) ->
        items =
          Enum.map(other, fn item -> if downcase?, do: String.downcase(item), else: item end)

        put_change(changeset, stored_field, items)
    end
  end

  defp validate_exclusive_scope(changeset) do
    member_id = get_field(changeset, :exclusive_to_group_member_id)
    group_id = get_field(changeset, :exclusive_to_group_id)
    service_id = get_field(changeset, :exclusive_to_service_id)
    set = Enum.count([member_id, group_id, service_id], &(&1 != nil))

    if set > 1 do
      add_error(
        changeset,
        :exclusive_to_group_member_id,
        "solo se puede asignar un scope exclusivo a la vez"
      )
    else
      changeset
    end
  end

  # Sync the virtual :scope field based on which FK is set, so the form
  # can use a single select to control scope.
  defp sync_scope_field(changeset) do
    member_id = get_field(changeset, :exclusive_to_group_member_id)
    group_id = get_field(changeset, :exclusive_to_group_id)
    service_id = get_field(changeset, :exclusive_to_service_id)

    scope =
      cond do
        member_id != nil -> "member"
        group_id != nil -> "group"
        service_id != nil -> "service"
        true -> "global"
      end

    put_change(changeset, :scope, scope)
  end

  # Keep sticky_ttl_ms (stored) and sticky_ttl_seconds (form) coherent. The
  # form submits seconds; we multiply by 1000 to populate ms. If the user
  # submitted nil for both (no sticky override), we leave nil — StickyTracker
  # then falls back to its 15-min default.
  defp sync_sticky_ttl_fields(changeset) do
    seconds = get_field(changeset, :sticky_ttl_seconds)
    ms = get_field(changeset, :sticky_ttl_ms)

    case {seconds, ms} do
      {nil, ms} when not is_nil(ms) ->
        changeset
        |> put_change(:sticky_ttl_seconds, div(ms, 1000))
        |> force_change(:sticky_ttl_ms, ms)

      {seconds, _} when not is_nil(seconds) ->
        ms_value = seconds * 1000

        changeset
        |> put_change(:sticky_ttl_ms, ms_value)
        |> force_change(:sticky_ttl_seconds, seconds)

      _ ->
        changeset
        |> put_change(:sticky_ttl_ms, nil)
        |> put_change(:sticky_ttl_seconds, nil)
    end
  end
end
