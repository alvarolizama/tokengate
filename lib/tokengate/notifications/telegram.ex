defmodule Tokengate.Notifications.Telegram do
  @moduledoc """
  Cliente mínimo de la Bot API de Telegram (sólo el envío saliente).

  El token se resuelve en este orden:

    1. `TELEGRAM_BOT_TOKEN` (runtime env → `:telegram_bot_token`), pensado
       para despliegues donde el secreto sale de la config del contenedor;
    2. el token **cifrado** guardado en `notification_settings`
       (`SecretBox.decrypt/1`), editable desde la sección de Operaciones.

  El envío usa `Req` sobre el pool `Tokengate.Finch` (el cliente HTTP preferido
  del proyecto) y devuelve la semántica de reintentos que espera el worker:
  `{:ok, message_id}` (entregado), `{:discard, reason}` (el destino o el token
  rechazan el mensaje — reintentar no ayuda) o `{:error, reason}` (transitorio).
  """

  @default_base "https://api.telegram.org"

  @doc "Whether a bot token is available at all."
  @spec configured?() :: boolean()
  def configured? do
    case token() do
      {:ok, _} -> true
      :error -> false
    end
  end

  @doc """
  Resolves the bot token, env first, decrypting the stored one as a fallback.
  """
  @spec token() :: {:ok, String.t()} | :error
  def token do
    case Application.get_env(:tokengate, :telegram_bot_token) do
      token when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> stored_token()
    end
  end

  defp stored_token do
    case Tokengate.Notifications.get_settings().bot_token do
      nil -> :error
      ciphertext -> Tokengate.Notifications.SecretBox.decrypt(ciphertext)
    end
  rescue
    _ -> :error
  end

  @doc """
  Sends a text message to `chat_id`. `opts` may carry `:parse_mode` and
  `:reply_markup` (an inline keyboard map, for the Fase-2 interactions).

  Returns `{:ok, message_id}`, `{:discard, reason}` or `{:error, reason}`.
  """
  @spec send_message(String.t() | integer(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:discard, String.t()} | {:error, String.t()}
  def send_message(chat_id, text, opts \\ []) do
    with {:ok, token} <- fetch_token() do
      payload =
        %{chat_id: chat_id, text: text}
        |> maybe_put(:parse_mode, opts[:parse_mode])
        |> maybe_put(:reply_markup, opts[:reply_markup])
        |> maybe_put(:message_thread_id, normalize_thread(opts[:message_thread_id]))

      post(token, "sendMessage", payload)
    end
  end

  @doc "Resolves the bot's `@username` via `getMe` (used by the settings UI)."
  @spec get_me() :: {:ok, String.t()} | {:error, String.t()}
  def get_me do
    with {:ok, token} <- fetch_token(),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           request(token, "getMe", %{}),
         %{"ok" => true, "result" => %{"username" => username}} <- body do
      {:ok, username}
    else
      {:ok, %{body: %{"description" => desc}}} -> {:error, desc}
      {:ok, %{status: status}} -> {:error, "getMe returned #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
      _ -> {:error, "unexpected getMe response"}
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_token do
    case token() do
      {:ok, token} -> {:ok, token}
      :error -> {:error, "Telegram bot token is not configured"}
    end
  end

  defp post(token, method, payload) do
    case request(token, method, payload) do
      {:ok, %{status: status, body: %{"ok" => true, "result" => result}}}
      when status in 200..299 ->
        {:ok, result["message_id"] && to_string(result["message_id"])}

      {:ok, %{status: status, body: %{"description" => desc}}} when status in 200..299 ->
        # 2xx but ok:false — bad chat, bot kicked, blocked. Retrying won't help.
        {:discard, "telegram rejected: #{desc}"}

      {:ok, %{status: status}} when status in 400..499 ->
        {:discard, "telegram returned #{status}"}

      {:ok, %{status: status}} ->
        {:error, "telegram returned #{status}"}

      {:error, reason} ->
        {:error, "transport error: #{inspect(reason)}"}
    end
  end

  defp request(token, method, payload) do
    Req.post("#{base()}/bot#{token}/#{method}",
      json: payload,
      receive_timeout: 15_000,
      finch: Tokengate.Finch
    )
  end

  defp base do
    Application.get_env(:tokengate, :telegram_api_base, @default_base)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `message_thread_id` is an integer in the Bot API; a channel/forum topic id
  # arrives from the UI as a string. A non-numeric value is dropped (the message
  # falls back to the chat's general thread) rather than failing the send.
  defp normalize_thread(nil), do: nil
  defp normalize_thread(value) when is_integer(value), do: value

  defp normalize_thread(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_thread(_), do: nil
end
