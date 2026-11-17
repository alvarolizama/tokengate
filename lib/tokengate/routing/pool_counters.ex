defmodule Tokengate.Routing.PoolCounters do
  @moduledoc """
  Rotación por request dentro de un pool: un contador `:atomics` por lane.

  Un lane montado sobre un pool (`model_providers.pool_id`) no tiene una
  credencial fija: cada request sirve con un miembro distinto. La rotación es
  uniforme y sin pesos, así que lo único que hay que recordar entre requests es
  por dónde empezó el anterior.

  ## Estado

    * `:tokengate_pool_counters` — ETS pública (`read_concurrency`) con
      `lane_id => :atomics.ref()`. La tabla la posee este GenServer; los
      procesos que atienden requests leen y avanzan el contador directo contra
      ETS, sin round-trip al servidor (es el hot path del proxy).
    * El ref se crea lazy con `:ets.insert_new/2`: dos requests concurrentes
      sobre el mismo lane no pelean, el que pierde la carrera reusa el ref del
      ganador.

  Los refs de lanes borrados no se limpian: son una entrada de ETS por lane
  (unos bytes) que nadie vuelve a leer. No se acumulan por request.

  ## Ausencia tolerada

  El contador es reparto, no correctitud: si la tabla no existe (tests
  aislados, `--no-start`, arranque parcial) `next_start/2` devuelve `0` en vez
  de crashear el request.
  """

  use GenServer

  @table :tokengate_pool_counters

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Índice de arranque (0-based) del siguiente request del lane `lane_id` en un
  pool de `n` miembros.

  Avanza el contador del lane y devuelve `rem(contador, n)`, siempre un índice
  válido en `0..n-1`. Devuelve `0` cuando `n` no es positivo o cuando el
  contador no está disponible.
  """
  @spec next_start(binary(), non_neg_integer()) :: non_neg_integer()
  def next_start(lane_id, n) when is_binary(lane_id) and is_integer(n) and n > 0 do
    case counter_ref(lane_id) do
      nil -> 0
      ref -> rem(:atomics.add_get(ref, 1, 1), n)
    end
  end

  def next_start(_lane_id, _n), do: 0

  @doc false
  def table, do: @table

  ## GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    table = ensure_table()
    {:ok, %{table: table}}
  end

  ## Internal -----------------------------------------------------------------

  # Idempotente a propósito: si el árbol de la app ya creó la tabla, un segundo
  # proceso (test que arranca su propio supervisor) no debe reventar por
  # `:ets.new/2` duplicado.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    else
      @table
    end
  end

  defp counter_ref(lane_id) do
    case :ets.lookup(@table, lane_id) do
      [{^lane_id, ref}] -> ref
      [] -> create_ref(lane_id)
    end
  rescue
    ArgumentError -> nil
  end

  # `:ets.insert_new/2` es la carrera resuelta: el primero gana y el resto lee
  # el ref que ya quedó. `signed: false` porque el contador sólo avanza.
  defp create_ref(lane_id) do
    ref = :atomics.new(1, signed: false)

    if :ets.insert_new(@table, {lane_id, ref}) do
      ref
    else
      case :ets.lookup(@table, lane_id) do
        [{^lane_id, existing}] -> existing
        [] -> ref
      end
    end
  rescue
    ArgumentError -> nil
  end
end
