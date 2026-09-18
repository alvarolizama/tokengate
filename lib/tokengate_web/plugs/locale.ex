defmodule TokengateWeb.Plugs.Locale do
  @moduledoc """
  Fija el locale de Gettext para el proceso de la request.

  Orden de resolución: el `:locale` de la sesión (útil antes de iniciar sesión)
  y, si no hay, `users.locale` del usuario que dejó cargado
  `TokengateWeb.Plugs.DashboardAuth`. Todo lo que no esté en `:locales` cae al
  locale de reserva.

  Va **después** de `DashboardAuth` en el pipeline `:browser`, porque necesita
  `:current_user`.

  Ojo: Gettext guarda el locale en el *process dictionary* y el proceso de un
  LiveView no es el de la request, así que este plug cubre sólo los
  controladores planos (login/logout, OAuth, redirects, exports, páginas de
  error). Los LiveViews lo reaplican en `TokengateWeb.UserAuth.on_mount/4`.
  """

  import Plug.Conn

  alias TokengateWeb.Gettext

  @session_key :locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = get_session(conn, @session_key) || user_locale(conn)
    Gettext.put_locale(locale)
    conn
  end

  defp user_locale(%{assigns: %{current_user: %{} = user}}), do: Gettext.locale_of(user)
  defp user_locale(_conn), do: Gettext.fallback_locale()
end
