defmodule TokengateWeb.ModelPicker do
  @moduledoc """
  Piezas compartidas por las dos pantallas del catálogo de modelos: el listado
  (`TokengateWeb.ModelsLive`) y la página de un modelo
  (`TokengateWeb.ModelProvidersLive`).

  Las dos necesitan las MISMAS primitivas — el descubrimiento de modelos que
  publica un proveedor, el id seguro para el DOM, la máscara de una API key y
  la normalización de la búsqueda — y ninguna es dueña de una pantalla. Viven
  aquí para que el alta (wizard) y el alta de un lane suelto no diverjan.

  `ModelsLive` reexporta las públicas con `defdelegate`: los tests las citan
  como contrato (`ModelsLive.dom_key/1`, `ModelsLive.list_provider_models/3`).
  """

  import Ecto.Query, only: [from: 2]
  import Phoenix.Component, only: [assign: 3]

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Providers.{Pricing, ServiceModels}
  alias Tokengate.Repo

  @doc """
  La referencia con la que la UI identifica a un proveedor: su key del catálogo
  (`fireworks-ai`) o, para un custom que no tiene, su id.
  """
  def provider_ref(provider), do: provider.key || provider.id

  def model_type_for(model_id) when is_binary(model_id) do
    case Providers.get_model(model_id) do
      nil -> "llm"
      model_ -> model_.model_type || "llm"
    end
  end

  def model_type_for(_model_id), do: "llm"

  def pricing_unit_options(model_id) do
    model_id
    |> model_type_for()
    |> Pricing.options_for_type()
    |> Enum.map(&{&1.label, &1.key})
  end

  @doc """
  True cuando la unidad elegida se cobra por tokens — es lo que decide si el
  form muestra los tres campos `*_cost_per_million` o el `unit_cost`.
  """
  def token_priced?(unit), do: Pricing.token_unit?(unit)

  # Provider keys whose OpenAI-compatible bodies can carry
  # `prompt_tokens_details.cache_write_tokens` (the counter
  # `UsageNormalizer` normalizes into `cache_creation_tokens`). Only for these
  # roots does a cache WRITE premium have anything to charge, so the form hides
  # the field for every other provider instead of offering a rate that can
  # never apply.
  @cache_write_provider_keys ~w(openai openrouter)

  @doc """
  True cuando el upstream del lane reporta tokens ESCRITOS en la caché de
  prompt (OpenAI-compatible: `openai`, `openrouter`). Es lo que decide si el
  form muestra la cuarta tarifa, `cache_write_cost_per_million`.
  """
  def cache_write_priced?(nil), do: false

  def cache_write_priced?(provider_key) when is_binary(provider_key),
    do: provider_key in @cache_write_provider_keys

  def cache_write_priced?(_provider_key), do: false

  @doc """
  Los modelos que ESTE proveedor publica para ESTE tipo — la fuente del paso 3:

    * si publica un catálogo POR SERVICIO (`?output_modalities=…`, hoy sólo
      OpenRouter), se lista ese endpoint, que es la fuente autoritativa;
    * si no, se lista su catálogo GENERAL — `/embeddings/models` para
      embeddings, `/models` para el resto — y se filtra por la familia del id
      (`ServiceModels.type_of/2`), que es lo que hace que la lista sea del TIPO
      elegido y no de todo lo que sirve el proveedor;
    * un proveedor que no publica NADA de ese tipo devuelve lista vacía y el paso
      se queda con la semilla curada (`wizard_seed_models/2`).

  Público porque es el contrato que el alta ofrece y lo que los tests ejercitan
  contra un upstream de mentira: `wizard_pick_model` no depende de su forma.
  """
  @spec list_provider_models(map(), map(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  #
  #   * si publica un catálogo POR SERVICIO (`?output_modalities=…`, hoy sólo
  #     OpenRouter), se lista ese endpoint, que es la fuente autoritativa;
  #   * si no, se lista su catálogo GENERAL — `/embeddings/models` para
  #     embeddings, `/models` para el resto — y se filtra por la familia del id
  #     (`ServiceModels.type_of/2`), que es lo que hace que la lista sea del
  #     TIPO elegido y no de todo lo que sirve el proveedor;
  #   * un proveedor que no publica NADA de ese tipo devuelve lista vacía y el
  #     paso se queda con la semilla curada (`wizard_seed_models/2`).
  def list_provider_models(provider, credential, type) do
    adapter = ProviderAdapter.dispatch(provider)

    case ServiceModels.discovery(provider.key, type) do
      nil ->
        listing =
          if type == "embedding" do
            adapter.list_embedding_models(provider, credential)
          else
            Tokengate.Proxy.OpenAIAdapter.list_models(provider, credential)
          end

        case listing do
          {:ok, ids} ->
            {:ok, Enum.filter(ids, &(ServiceModels.type_of(provider.key, &1) == type))}

          {:error, reason} ->
            {:error, reason}
        end

      endpoint ->
        adapter.list_service_models(provider, credential, endpoint)
    end
  end

  def resolve_scope_search(%{"value" => search}), do: %{search: search}

  def resolve_scope_search(%{"model_provider" => %{"value" => search}}),
    do: %{search: search}

  def resolve_scope_search(%{"model_provider" => %{"scope_member_id_display" => search}}),
    do: %{search: search || ""}

  def resolve_scope_search(%{"model_provider" => %{"scope_group_id_display" => search}}),
    do: %{search: search || ""}

  def resolve_scope_search(_params), do: %{search: ""}

  def query_param(params) when is_map(params) do
    params
    |> Enum.flat_map(fn
      {_key, %{} = nested} -> Map.to_list(nested)
      {key, value} -> [{key, value}]
    end)
    |> Enum.find_value("", fn
      {key, value} when key in ["value", "q"] and is_binary(value) -> value
      _ -> nil
    end)
  end

  def query_param(_), do: ""

  @doc """
  A DOM-id-safe, INJECTIVE rendering of a provider/model id.

  Ids carry `/`, `@`, `:`, `~` and `.` (`openai/gpt-5-nano`,
  `@cf/meta/llama-3.1-8b-instruct`, `glm-5.2`), none of which are valid in a CSS
  selector: a raw id would break every `element/2` lookup and any client-side
  selector.

  A plain substitution is NOT enough: `/` and `-` both collapse to `-` (and `.`
  to `_`), so `openai/gpt-5-nano` and `openai-gpt-5-nano` — two DISTINCT ids —
  render the same DOM id and LiveView raises `Duplicate id found`.

  So the sanitized form is kept for readability and, whenever the key was
  rewritten at all, a short hash of the ORIGINAL key is appended: the transform
  stays injective while a human can still read the prefix. A key already made of
  `[A-Za-z0-9_-]` is returned untouched, so provider keys like `fireworks-ai`
  keep their plain id.
  """
  def dom_key(key) when is_binary(key) do
    sanitized = sanitize_dom_key(key)

    if sanitized == key do
      sanitized
    else
      sanitized <> "-" <> key_hash(key)
    end
  end

  def dom_key(key), do: to_string(key)

  defp sanitize_dom_key(key) do
    key
    |> String.replace(".", "_")
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp key_hash(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  def assign_form_data(socket) do
    credentials =
      from(c in Tokengate.Providers.Credential,
        where: c.status == "active",
        preload: [:provider]
      )
      |> Repo.all()
      |> Enum.sort_by(fn credential ->
        {String.downcase(credential.provider.name), String.downcase(credential.name || "")}
      end)

    socket
    |> assign(:credentials_for_select, credentials)
  end

  def assign_scope_data(socket) do
    groups = Accounts.list_groups()

    members =
      from(tm in Tokengate.Accounts.GroupMember,
        preload: [:user],
        order_by: [asc: tm.id]
      )
      |> Repo.all()

    socket
    |> assign(:groups_for_select, groups)
    |> assign(:members_for_select, members)
  end

  # El path del endpoint /v1 que sirve cada tipo de modelo — el mismo contrato
  # que lib/tokengate_web/router.ex expone y que Routing.Router hace cumplir
  # (capability = model_type). `nil` para un tipo fuera del vocabulario: la
  # fila no muestra endpoint en vez de mostrar uno mentiroso.
  @type_endpoints %{
    "llm" => "POST /v1/chat/completions",
    # La superficie pública canónica de decisiones: el shape OpenAI
    # (`/v1/decisions`), con traducción a System One para los proveedores que
    # hablan ese wire. El camino de chat de TypeSafe queda por compatibilidad.
    "decision" => "POST /v1/decisions",
    "embedding" => "POST /v1/embeddings",
    # Rerank: contrato canónico propio (`{model, query, documents, top_n}` →
    # `results[] {index, relevance_score}`). La traducción por proveedor vive
    # en `Tokengate.Proxy.Rerank`; el path upstream lo pone `ProviderPaths`.
    "rerank" => "POST /v1/rerank",
    "stt" => "POST /v1/audio/transcriptions",
    "tts" => "POST /v1/audio/speech",
    "image" => "POST /v1/images/generations"
  }

  @doc "The /v1 endpoint that serves a model type (nil when unknown)."
  @spec type_endpoint(String.t() | nil) :: String.t() | nil
  def type_endpoint(type) when is_binary(type), do: Map.get(@type_endpoints, type)
  def type_endpoint(_), do: nil

  @doc "The full type → endpoint map, as pairs (testable surface)."
  @spec type_endpoint_pairs() :: [{String.t(), String.t()}]
  def type_endpoint_pairs, do: Enum.to_list(@type_endpoints)

  @doc "Número compacto para la UI: 1.5B, 128.0K, 200."
  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  @doc "Máscara de una API key: sólo los últimos 4 caracteres."
  def mask_key(nil), do: "—"
  def mask_key(""), do: "—"
  def mask_key(key) when byte_size(key) <= 4, do: "****"

  def mask_key(key) do
    len = String.length(key)

    String.slice(key, len - 4, 4)
    |> then(&"••••••#{&1}")
  end

  @doc """
  La credencial que se preselecciona cuando el proveedor publica UNA sola key:
  con una sola no hay nada que elegir.
  """
  def default_credential_id([single]), do: single.id
  def default_credential_id(_), do: nil

  @doc "Acota el select de credenciales a las del proveedor elegido (o todas si no hay)."
  def assign_credential_choices(socket) do
    choices =
      case socket.assigns[:provider_form_provider_key] do
        nil -> socket.assigns[:credentials_for_select] || []
        _ -> socket.assigns[:provider_credentials] || []
      end

    assign(socket, :credential_choices, choices)
  end

  def credential_options(credentials) do
    Enum.map(credentials, fn c ->
      label =
        if c.name do
          "#{c.provider.name} · #{c.name} · #{mask_key(c.api_key_encrypted)}"
        else
          "#{c.provider.name} · #{mask_key(c.api_key_encrypted)}"
        end

      {label, c.id}
    end)
  end

  @doc "Formatea un decimal para la UI (— cuando no hay valor)."
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Precio: hasta 6 decimales, sin ceros de cola (0.55, 0.000012)."
  def fmt_price(%Decimal{} = d),
    do: d |> Decimal.round(6) |> Decimal.normalize() |> Decimal.to_string(:normal)

  def fmt_price(nil), do: "—"
  def fmt_price(n), do: fmt_dec(n)
end
