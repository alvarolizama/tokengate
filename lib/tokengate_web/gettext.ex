defmodule TokengateWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://gettext.hexdocs.pm), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: TokengateWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.

  ## Locales de la UI

  El idioma de la UI es **inglés** (el `msgid` es la fuente) y el español vive en
  `priv/gettext/es/LC_MESSAGES/*.po`. `:locales` declara lo que ofrece el selector
  del sidebar y `:default_locale` lo que se usa cuando nadie ha elegido; las
  funciones de abajo son el único punto que lee esa configuración.
  """

  use Gettext.Backend, otp_app: :tokengate

  @doc """
  Locales que la UI ofrece, según `:locales` en la config del backend.
  """
  @spec ui_locales() :: [String.t()]
  def ui_locales, do: Keyword.get(config(), :locales, [fallback_locale()])

  @doc """
  Locale de reserva cuando nadie ha elegido, según `:default_locale`.
  """
  @spec fallback_locale() :: String.t()
  def fallback_locale, do: Keyword.get(config(), :default_locale, "en")

  @doc """
  Normaliza un locale: devuelve el de reserva si no está soportado.

  Existe para que ningún locale inventado (query string, cookie o sesión vieja)
  llegue a `Gettext.put_locale/2`.
  """
  @spec normalize_locale(term()) :: String.t()
  def normalize_locale(locale) when is_binary(locale) do
    if locale in ui_locales(), do: locale, else: fallback_locale()
  end

  def normalize_locale(_), do: fallback_locale()

  @doc """
  Aplica `locale` al proceso actual y devuelve el locale ya normalizado.

  Gettext guarda el locale en el *process dictionary*, así que hay que llamarlo
  en **cada** proceso que traduzca: el plug lo hace para las requests y
  `TokengateWeb.UserAuth` para el proceso de cada LiveView.
  """
  @spec put_locale(term()) :: String.t()
  def put_locale(locale) do
    locale = normalize_locale(locale)
    # `Elixir.Gettext` explícito: dentro de un módulo `A.B`, un `B` a secas se
    # resuelve a `A.B` (este mismo módulo), no a la librería Gettext.
    Elixir.Gettext.put_locale(__MODULE__, locale)
    locale
  end

  @doc """
  Locale activo en el **proceso actual** (lo que ya se aplicó con
  `put_locale/1`); el atributo `lang` del `<html>` sale de aquí.
  """
  @spec current_locale() :: String.t()
  def current_locale, do: Elixir.Gettext.get_locale(__MODULE__)

  @doc """
  Locale a usar para un usuario (`users.locale`), normalizado. `nil` → reserva.
  """
  @spec locale_of(map() | nil) :: String.t()
  def locale_of(nil), do: fallback_locale()
  def locale_of(%{locale: locale}), do: normalize_locale(locale)
  def locale_of(_), do: fallback_locale()

  @doc """
  Traduce un `msgid` que sólo se conoce en runtime (no es un literal del código).

  El macro `gettext/1` exige un literal para poder extraerlo; para valores que
  vienen de datos o de un `attr` hay que usar esta función. Esas entradas del
  `.po` se mantienen a mano (la extracción no las ve).
  """
  @spec translate(term()) :: String.t()
  def translate(msgid), do: Elixir.Gettext.gettext(__MODULE__, msgid)

  defp config, do: Application.get_env(:tokengate, __MODULE__, [])
end
