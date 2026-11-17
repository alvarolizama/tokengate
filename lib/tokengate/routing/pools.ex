defmodule Tokengate.Routing.Pools do
  @moduledoc """
  Pools de credenciales vistos por el router: expansión, agrupación, salud
  agregada y tope por request.

  Un lane de `model_providers` con `pool_id` no apunta a una credencial: apunta
  a un pool del mismo provider. Para el router eso significa que el lane se
  materializa como N candidatos —uno por miembro, cada uno una COPIA del lane
  con la credencial del miembro ya puesta y el `id` del lane intacto— **antes**
  de cualquier filtro. Así el filtro por credencial (`mp.credential != nil`,
  estado, exclude, visibilidad) y el breaker corren POR MIEMBRO, mientras
  prioridad, `provider_model`, precio y scope siguen siendo del lane (una sola
  fila que el operador edita una vez).

  El `id` intacto es lo que permite volver a agrupar: `group/1` recompone los
  grupos por `model_provider.id`, y `Priority.select_groups/2` elige primero el
  grupo y después el miembro. Un lane de una sola key es un grupo de un
  candidato, así que conserva su sticky y su orden actual.

  ## Salud del grupo

  `health/1` se calcula de los CANDIDATOS, nunca del campo `credential` del
  lane: en un lane de pool ese campo es `nil`, y `Priority` trata un candidato
  sin credencial como sano (atajo válido para structs armados a mano, pero
  mentira para un pool). El grupo es nivel 1 sólo cuando TODOS sus candidatos
  están degraded.

  ## Tope por request

  `cap/1` es `min(n, max(1, round(n * 0.8)))` — el 80% de los miembros con piso
  de uno y sin pasarse nunca de `n`. `cap_for/1` lo aplica al grupo: el tamaño
  de su pool para un lane con `pool_id`, uno para un lane de una sola key.

  El conteo de intentos va sobre `lane.pool.members`, **no** sobre `candidates`:
  el router filtra las credenciales excluidas ANTES de agrupar, así que contar
  candidatos daría siempre cero y el tope no se alcanzaría nunca. `exhausted?/2`
  compara `tried_in_group/2` contra `cap_for/1`, y `Priority.select_groups/2`
  salta los grupos agotados para que la cascada caiga al siguiente grupo (o al
  lane suelto) en vez de seguir mordiendo el pool.
  """

  alias Tokengate.Providers.{Credential, CredentialPool, ModelProvider}
  alias Tokengate.Routing.CredentialHealth

  defmodule Group do
    @moduledoc """
    Un lane con sus candidatos ya expandidos.

    `lane` es la copia que abrió el grupo (mismos `id`, `priority`, `pool_id`,
    scope y `provider_model` que todas las demás; la credencial es la del primer
    miembro, así que **no** se usa para leer salud ni credencial: para eso están
    `candidates`).
    """

    @type t :: %__MODULE__{
            id: term(),
            lane: ModelProvider.t(),
            candidates: [ModelProvider.t()]
          }

    defstruct [:id, :lane, :candidates]
  end

  @doc """
  Materializa los lanes cacheados en candidatos.

  Un lane con pool se convierte en una copia por miembro (ordenadas por
  `credential_id`, deterministas entre refrescos del cache) con la credencial
  del miembro y el `id` del lane. Un lane de una sola key pasa tal cual. Un pool
  sin miembros no produce candidatos: el lane no sirve y no debe llegar al
  filtro con `credential: nil`.
  """
  @spec expand([ModelProvider.t()]) :: [ModelProvider.t()]
  def expand(lanes) when is_list(lanes), do: Enum.flat_map(lanes, &expand_lane/1)

  @doc """
  Agrupa candidatos por `model_provider.id`, conservando el orden de primera
  aparición y el lane que abrió cada grupo.
  """
  @spec group([ModelProvider.t()]) :: [Group.t()]
  def group(candidates) when is_list(candidates) do
    # `order` is the first-appearance order; `by_id` holds the group itself.
    # Positions are NOT tracked against an index: a list built by prepending
    # shifts every stored index, which used to fold a later lane's members into
    # the group before it.
    {order, by_id} =
      Enum.reduce(candidates, {[], %{}}, fn %ModelProvider{id: id} = candidate, {order, by_id} ->
        case Map.fetch(by_id, id) do
          {:ok, group} ->
            {order, Map.put(by_id, id, append_candidate(group, candidate))}

          :error ->
            group = %Group{id: id, lane: candidate, candidates: [candidate]}
            {order ++ [id], Map.put(by_id, id, group)}
        end
      end)

    Enum.map(order, &Map.fetch!(by_id, &1))
  end

  @doc """
  Tope de miembros que la cascada puede intentar en un request:
  `min(n, max(1, round(n * 0.8)))` (2→2, 3→2, 5→4, 10→8). `0` para `n <= 0`.
  """
  @spec cap(integer()) :: non_neg_integer()
  def cap(n) when is_integer(n) and n > 0, do: min(n, max(1, round(n * 0.8)))
  def cap(_n), do: 0

  @doc """
  Tope de miembros que la cascada puede intentar en este grupo:
  `cap/1` sobre el tamaño del pool de un lane con `pool_id`, y `1` para un lane
  de una sola key.

  Se lee `lane.pool.members` —el pool COMPLETO— y no `candidates`: los miembros
  ya excluidos por la cascada dejaron de ser candidatos, así que el tamaño de
  `candidates` no es el del pool.
  """
  @spec cap_for(Group.t()) :: non_neg_integer()
  def cap_for(%Group{lane: %ModelProvider{pool: %CredentialPool{members: members}}})
      when is_list(members),
      do: cap(length(members))

  def cap_for(%Group{}), do: 1

  @doc """
  Cuántos miembros del grupo ya se intentaron: los miembros del pool del lane
  cuyo `credential_id` está en `exclude` (`:exclude_credential_ids` de la
  cascada). Para un lane de una sola key: `1` si su credencial está excluida.

  Los ya excluidos NO están en `candidates` (el router los filtra antes de
  agrupar), así que el conteo sale de `lane.pool.members`; contar candidatos
  daría cero y `exhausted?/2` nunca dispararía.
  """
  @spec tried_in_group(Group.t(), [term()] | nil) :: non_neg_integer()
  def tried_in_group(%Group{lane: lane, candidates: candidates}, exclude) do
    excluded = MapSet.new(List.wrap(exclude))

    case lane do
      %ModelProvider{pool: %CredentialPool{members: members}} when is_list(members) ->
        Enum.count(members, &MapSet.member?(excluded, member_credential_id(&1)))

      _single_key_or_unloaded_pool ->
        Enum.count(candidates, &MapSet.member?(excluded, credential_id(&1)))
    end
  end

  @doc """
  `true` cuando el grupo ya gastó su tope: `tried_in_group/2 >= cap_for/1`.

  Un grupo agotado no debe recibir otro intento: `Priority.select_groups/2` lo
  salta y la cascada cae al siguiente grupo.
  """
  @spec exhausted?(Group.t(), [term()] | nil) :: boolean()
  def exhausted?(%Group{} = group, exclude),
    do: tried_in_group(group, exclude) >= cap_for(group)

  @doc """
  Salud agregada del grupo: `0` si al menos un candidato está sano, `1` sólo si
  todos los candidatos están degraded.

  Un candidato sin credencial cargada no puede estar degraded (`CredentialHealth`
  es por credencial): cuenta como sano, igual que en `Priority`. Lo que NO se
  hace es leer `lane.credential`, que en un lane de pool es `nil`.
  """
  @spec health(Group.t()) :: 0 | 1
  def health(%Group{candidates: candidates}) do
    if Enum.any?(candidates, &(not degraded?(&1))), do: 0, else: 1
  end

  ## Internal -----------------------------------------------------------------

  defp expand_lane(%ModelProvider{pool: %CredentialPool{members: members}} = lane)
       when is_list(members) do
    members
    |> Enum.sort_by(&member_order/1)
    |> Enum.flat_map(fn
      %{credential: %Credential{} = credential} -> [%{lane | credential: credential}]
      _ -> []
    end)
  end

  # Lane de una sola key, o pool sin preload (`%Ecto.Association.NotLoaded{}`):
  # se deja como está y el filtro del router decide.
  defp expand_lane(%ModelProvider{} = lane), do: [lane]

  defp member_order(%{credential_id: credential_id, id: id}), do: {credential_id, id}
  defp member_order(_member), do: {nil, nil}

  defp append_candidate(%Group{candidates: candidates} = group, candidate),
    do: %{group | candidates: candidates ++ [candidate]}

  defp credential_id(%ModelProvider{credential: %{id: id}}), do: id
  defp credential_id(_candidate), do: nil

  # `credential_id` del miembro del pool (la copia del lane, en cambio, lleva la
  # credencial en `credential`).
  defp member_credential_id(%{credential_id: credential_id}), do: credential_id
  defp member_credential_id(_member), do: nil

  defp degraded?(%ModelProvider{credential: %{id: id}}) when is_binary(id),
    do: CredentialHealth.degraded?(id)

  defp degraded?(_candidate), do: false
end
