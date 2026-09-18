# Reproducción del bug 402: hold/settle del contador del límite.
# Ejecutar: mix run priv/repo/probes/repro_402_limit.exs
alias Tokengate.Budgets.Manager
alias Decimal

subject = {:service, Ecto.UUID.generate()}
key = {:limit, subject}
:ets.delete(:tokengate_credits, key)

today = Date.utc_today()
:ets.insert(:tokengate_credits, {key, 9_500_000, nil, {today.year, today.month}, true, nil, true})

plan = %{subject: subject, limit_usd: Decimal.new("10.00"), unlimited?: false, topups: []}

{:ok, h1} = Manager.reserve_plan(plan, nil, Decimal.new("1.00"), false)

IO.puts("subject_micro del hold: #{h1.subject_micro} (esperado 1_000_000)")

Manager.settle_credits(h1, Decimal.new("0.30"))
c1 = :ets.lookup_element(:tokengate_credits, key, 2)
IO.puts("settle 0.30 tras hold 1.00: counter=#{c1} (esperado 9_800_000) #{if c1 == 9_800_000, do: "OK", else: "FAIL"}")

{:ok, h2} = Manager.reserve_plan(plan, nil, Decimal.new("1.00"), false)
Manager.release_credits(h2)
c2 = :ets.lookup_element(:tokengate_credits, key, 2)
IO.puts("release tras hold:          counter=#{c2} (esperado 9_800_000) #{if c2 == 9_800_000, do: "OK", else: "FAIL"}")

# cap global rechaza → rollback del delta del sujeto
{:error, {:budget_exceeded, %{layer: :global}}} =
  Manager.reserve_plan(plan, Decimal.new("0.01"), Decimal.new("1.00"), false)

c3 = :ets.lookup_element(:tokengate_credits, key, 2)
IO.puts("rollback cap global:        counter=#{c3} (esperado 9_800_000) #{if c3 == 9_800_000, do: "OK", else: "FAIL"}")

# límite real: 9.80 gastado, quedan 0.20 → hold de 1.00 pasa (hold, no hard-stop),
# pero el SIGUIENTE debe rechar si ya está en el tope
{:ok, h4} = Manager.reserve_plan(plan, nil, Decimal.new("0.15"), false)
Manager.settle_credits(h4, Decimal.new("0.15"))
c4 = :ets.lookup_element(:tokengate_credits, key, 2)
IO.puts("gasto hasta 9.95:           counter=#{c4} (esperado 9_950_000) #{if c4 == 9_950_000, do: "OK", else: "FAIL"}")

# re-siembra manual (lo que hace el SyncWorker con credit_subject)
Manager.reseed_limit_counter(subject)
c5 = :ets.lookup_element(:tokengate_credits, key, 2)
IO.puts("reseed desde DB:            counter=#{c5} (esperado 9_950_000 — sin logs reales de este sujeto) #{if c5 == 9_950_000, do: "OK", else: "FAIL"}")

:ets.delete(:tokengate_credits, key)
