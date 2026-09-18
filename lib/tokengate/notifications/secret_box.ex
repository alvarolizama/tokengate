defmodule Tokengate.Notifications.SecretBox do
  @moduledoc """
  Cifrado autenticado (AEAD) del token del bot de Telegram en reposo.

  El token es un secreto con poder real: quien lo tenga controla el bot. No se
  guarda en claro en la base. Se cifra con `Plug.Crypto.MessageEncryptor`
  (XChaCha20-Poly1305 con clave derivada de `secret_key_base`), de modo que leer
  la fila de `notification_settings` no basta para recuperarlo.

  La clave se deriva de `secret_key_base`, que en producción viene de
  `SECRET_KEY_BASE` (obligatorio, ver `config/runtime.exs`). En dev/test hay un
  valor conocido — correcto para desarrollo, inaceptable en producción.
  """

  @salt "Tokengate.Notifications.SecretBox"
  @aad "tokengate.notifications.bot_token"

  @doc "Encrypts a plaintext token. Returns the ciphertext blob."
  @spec encrypt(String.t()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    Plug.Crypto.MessageEncryptor.encrypt(plaintext, @aad, key(), @salt)
  end

  @doc """
  Decrypts a token blob. Returns `{:ok, token}` or `:error` when the ciphertext
  is missing, tampered with, or was produced under a different key.
  """
  @spec decrypt(binary() | nil) :: {:ok, String.t()} | :error
  def decrypt(nil), do: :error

  def decrypt(ciphertext) when is_binary(ciphertext) do
    Plug.Crypto.MessageEncryptor.decrypt(ciphertext, @aad, key(), @salt)
  rescue
    _ -> :error
  end

  def decrypt(_), do: :error

  @doc false
  def key do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @salt)
  end

  defp secret_key_base do
    :tokengate
    |> Application.get_env(TokengateWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base) ||
      raise "secret_key_base is not configured; cannot encrypt notification secrets"
  end
end
