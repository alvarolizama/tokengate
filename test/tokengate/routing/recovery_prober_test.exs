defmodule Tokengate.Routing.RecoveryProberTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.Providers
  alias Tokengate.Routing.{CircuitBreakerManager, RecoveryProber}

  @threshold 2
  @cooldown_ms 30

  setup do
    prev = Application.get_env(:tokengate, :circuit_breaker)

    Application.put_env(:tokengate, :circuit_breaker,
      cooldown_ms: @cooldown_ms,
      threshold: @threshold,
      rate_limit_cooldown_ms: 20
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:tokengate, :circuit_breaker, prev)
      else
        Application.delete_env(:tokengate, :circuit_breaker)
      end
    end)

    u = System.unique_integer([:positive])

    {:ok, provider} =
      Providers.create_provider(%{
        name: "Prober Provider #{u}",
        base_url: "http://127.0.0.1:1/v1"
      })

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-prober-#{u}"
      })

    on_exit(fn -> CircuitBreakerManager.reset(credential.id) end)

    {:ok, credential: credential}
  end

  test "probe_async closes a :half_open breaker when health_check returns :ok", %{
    credential: credential
  } do
    trip_to_half_open(credential.id)

    parent = self()

    RecoveryProber.probe_async(credential.id,
      health_check_fun: fn _prov, _cred ->
        send(parent, :health_checked)
        :ok
      end
    )

    assert_receive :health_checked, 1_000
    assert_eventually(fn -> CircuitBreakerManager.status(credential.id) == :closed end)
  end

  test "probe_async reopens a :half_open breaker when health_check fails with :server_error", %{
    credential: credential
  } do
    trip_to_half_open(credential.id)

    parent = self()

    RecoveryProber.probe_async(credential.id,
      health_check_fun: fn _prov, _cred ->
        send(parent, :health_checked)
        {:error, :server_error}
      end
    )

    assert_receive :health_checked, 1_000
    assert_eventually(fn -> CircuitBreakerManager.status(credential.id) == :open end)
  end

  test "probe_async releases probe slot on non-counting 404 without reopening or falsely closing",
       %{credential: credential} do
    trip_to_half_open(credential.id)

    parent = self()

    RecoveryProber.probe_async(credential.id,
      health_check_fun: fn _prov, _cred ->
        send(parent, :health_checked)
        {:error, :client_error}
      end
    )

    assert_receive :health_checked, 1_000

    assert_eventually(fn ->
      CircuitBreakerManager.status(credential.id) == :half_open and
        CircuitBreakerManager.usable?(credential.id) == true
    end)
  end

  defp trip_to_half_open(cred_id) do
    for _ <- 1..@threshold do
      CircuitBreakerManager.record_failure(cred_id, :server_error)
    end

    assert CircuitBreakerManager.status(cred_id) == :open
    assert_eventually(fn -> CircuitBreakerManager.status(cred_id) == :half_open end)
  end

  defp assert_eventually(predicate, attempts \\ 0)

  defp assert_eventually(_predicate, 400),
    do: flunk("assert_eventually: condition never became true")

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      receive do
      after
        5 -> :ok
      end

      assert_eventually(predicate, attempts + 1)
    end
  end
end
