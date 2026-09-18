defmodule Tokengate.Notifications.Settings do
  @moduledoc """
  Ajustes singleton del bot de Telegram (patrón `Tokengate.GlobalSettings`).

  Una única fila `id = 1`:

    * `bot_token` — el token del bot **cifrado** (AEAD, ver
      `Tokengate.Notifications.SecretBox`). Nunca se guarda en claro ni se
      registra en logs (`:filter_parameters` ya cubre `token`/`secret`).
    * `bot_username` — el `@username` resuelto por `getMe`, sólo informativo.
    * `enabled_events` — mapa `%{"event_name" => true | false}`; lo que no
      figure se resuelve con el default del catálogo (`Events`).
    * `quiet_hours_from` / `quiet_hours_to` — ventana `"HH:MM"` en UTC donde
      sólo pasan los eventos `:critical` (nil = sin silencio).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @singleton_id 1

  schema "notification_settings" do
    field :bot_token, :binary
    field :bot_username, :string
    field :enabled_events, :map, default: %{}
    field :quiet_hours_from, :string
    field :quiet_hours_to, :string

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(bot_username enabled_events quiet_hours_from quiet_hours_to)a

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @permitted)
    |> validate_quiet_hours()
  end

  @doc "Changeset for writing the encrypted bot token (kept out of `cast`)."
  def token_changeset(settings, ciphertext) do
    change(settings, bot_token: ciphertext)
  end

  # Las dos horas van juntas o ninguna: media ventana no significa nada.
  defp validate_quiet_hours(changeset) do
    from = get_field(changeset, :quiet_hours_from)
    to = get_field(changeset, :quiet_hours_to)

    if present?(from) != present?(to) do
      add_error(changeset, :quiet_hours_from, "define both quiet-hours bounds or neither")
    else
      changeset
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  @doc "Fixed primary key of the singleton row."
  def singleton_id, do: @singleton_id
end
