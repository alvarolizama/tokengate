defmodule Tokengate.Providers.ProviderLimits do
  @moduledoc """
  The operational limits of a provider, in one place.

  A credential is only an alias + secret, so the throttle lives on the
  provider (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`,
  `receive_timeout_ms`) and every key attached to it inherits the same gate.

  `nil` means unlimited for the three rate gates. For the receive timeout,
  `nil` means "use the global default" — the `:receive_timeout_ms` value under
  `config :tokengate, :proxy` (env `PROXY_RECEIVE_TIMEOUT_MS`), 120s out of the
  box — so a provider that never sets one keeps the global behaviour.
  """

  # Fallback applied when neither the provider nor the env sets a timeout.
  @global_timeout_ms 120_000

  @doc """
  Global receive timeout (ms) — the value used for providers that don't
  define their own.
  """
  def default_receive_timeout_ms do
    :tokengate
    |> Application.get_env(:proxy, [])
    |> Keyword.get(:receive_timeout_ms, @global_timeout_ms)
  end

  @doc """
  Effective upstream receive timeout (ms) for a provider: its own value when
  set, the global default otherwise.
  """
  def receive_timeout_ms(%{receive_timeout_ms: ms}) when is_integer(ms), do: ms
  def receive_timeout_ms(_provider), do: default_receive_timeout_ms()
end
