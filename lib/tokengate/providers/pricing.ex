defmodule Tokengate.Providers.Pricing do
  @moduledoc """
  La UNIDAD en la que se cobra una llamada.

  El coste manual de un `model_provider` nació midiendo tokens
  (`input/output/cache_cost_per_million`), y eso describe bien la mitad de la
  superficie del gateway: chat, embeddings, decisiones y rerank se facturan por
  tokens. Los otros seis servicios no:

      tipo      unidad real facturable                unidad por defecto
      --------  ------------------------------------  -----------------------
      image     por imagen, o por megapíxel           per_image
      video     por segundo de vídeo                  per_second
      music     por segundo (o por generación)        per_second
      tts       por mil caracteres de entrada, o seg  per_1k_characters
      stt       por minuto de audio transcrito        per_minute
      rerank    por tokens de búsqueda                per_1m_tokens

  Este módulo es el VOCABULARIO (cerrado) y el puente tipo → unidad: qué
  unidades TIENEN sentido para cada tipo, cuál es la de por defecto, y el
  divisor con el que una cantidad se convierte en múltiplos de la unidad
  (`per_1k_characters` divide por 1000).

  ## Qué NO decide

  No decide el precio: eso es `model_providers.unit_cost`, por lane. Tampoco
  decide el coste final: `Tokengate.Proxy.CostCalculator` es el único punto que
  cobra, y el coste reportado por el upstream le gana siempre a esta ruta.
  """

  use Gettext, backend: TokengateWeb.Gettext

  # Vocabulario cerrado. Las de token son las dos únicas que leen los tres
  # campos `*_cost_per_million`; el resto se cobra con `unit_cost`.
  @token_units ~w(per_1m_tokens per_1k_tokens)

  @units ~w(
    per_1m_tokens per_1k_tokens per_request per_image per_megapixel
    per_second per_minute per_1k_characters
  )

  @default_unit "per_1m_tokens"

  @labels %{
    "per_1m_tokens" => "per 1M tokens",
    "per_1k_tokens" => "per 1K tokens",
    "per_request" => "per request",
    "per_image" => "per image",
    "per_megapixel" => "per megapixel",
    "per_second" => "per second",
    "per_minute" => "per minute",
    "per_1k_characters" => "per 1K characters"
  }

  @doc "El vocabulario cerrado de unidades."
  @spec units() :: [String.t()]
  def units, do: @units

  @doc "La unidad por defecto: la de siempre (tokens por millón)."
  @spec default_unit() :: String.t()
  def default_unit, do: @default_unit

  @doc "True cuando la unidad se cobra por tokens (los 3 campos de token aplican)."
  @spec token_unit?(String.t() | nil) :: boolean()
  def token_unit?(unit), do: unit in @token_units

  @doc """
  Las unidades que se cobran por tokens.

  Público porque hay un consumidor que necesita distinguirlas fuera de aquí: el
  backfill de coste sólo puede recalcular filas de token — la cantidad de una
  unidad de media (nº de imágenes, segundos) no está en el log, así que no es
  reconstruible a posteriori.
  """
  @spec token_units() :: [String.t()]
  def token_units, do: @token_units

  @doc "The units that make sense for a model type, in display order."
  @spec units_for_type(String.t() | nil) :: [String.t()]
  def units_for_type(type) do
    case type do
      "image" -> ~w(per_image per_megapixel per_request)
      "video" -> ~w(per_second per_request)
      "music" -> ~w(per_second per_request)
      # TTS: la duración del audio generado NO es reconstruible desde la
      # respuesta de un endpoint de síntesis, así que no se ofrece `per_second`
      # — ofrecerlo daría una unidad que siempre cobra $0.
      "tts" -> ~w(per_1k_characters per_request)
      "stt" -> ~w(per_minute per_second per_request)
      _ -> ~w(per_1m_tokens per_1k_tokens per_request)
    end
  end

  @doc """
  La unidad por defecto con la que se cobra un tipo de modelo.

  Es sólo el DEFAULT que el formulario propone: el operador puede cambiarlo,
  porque dos proveedores del mismo tipo pueden cobrar distinto (una imagen fija
  vs. por megapíxel).
  """
  @spec default_unit_for_type(String.t() | nil) :: String.t()
  def default_unit_for_type(type) do
    case type do
      "image" -> "per_image"
      "video" -> "per_second"
      "music" -> "per_second"
      "tts" -> "per_1k_characters"
      "stt" -> "per_minute"
      _ -> @default_unit
    end
  end

  @doc """
  Divisor de la unidad: en cuántas unidades base se mide un precio unitario.

  `per_1m_tokens` → 1_000_000, `per_1k_tokens` y `per_1k_characters` → 1_000,
  y el resto → 1 (el precio YA es por unidad). Es lo que permite escribir
  `cantidad × precio / divisor` con una sola fórmula.
  """
  @spec divisor(String.t() | nil) :: pos_integer()
  def divisor("per_1m_tokens"), do: 1_000_000
  def divisor("per_1k_tokens"), do: 1_000
  def divisor("per_1k_characters"), do: 1_000
  def divisor(_unit), do: 1

  @doc """
  Etiqueta legible de una unidad, en el idioma del usuario.

  Traducida al leer (las etiquetas guardadas son msgid en inglés), igual que
  `ProviderPaths.services/0`.
  """
  @spec label(String.t() | nil) :: String.t()
  def label(unit) do
    @labels |> Map.get(unit, unit) |> TokengateWeb.Gettext.translate()
  end

  @doc """
  Las unidades de un tipo como `[%{key:, label:}]`, listas para un select.
  """
  @spec options_for_type(String.t() | nil) :: [%{key: String.t(), label: String.t()}]
  def options_for_type(type) do
    type
    |> units_for_type()
    |> Enum.map(&%{key: &1, label: label(&1)})
  end
end
