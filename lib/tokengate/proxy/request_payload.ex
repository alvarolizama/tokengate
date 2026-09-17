defmodule Tokengate.Proxy.RequestPayload do
  @moduledoc """
  Preparación del payload que sale hacia el upstream.

  ## Por qué: un `null` explícito NO es lo mismo que una clave omitida

  El proxy es passthrough: el JSON del cliente se re-encodea y se reenvía tal
  como llegó. Pero los SDK y los agentes de CLI suelen serializar como `null`
  explícito los knobs que no usan (`"max_tokens": null`, `"temperature":
  null`, `"stream": null`, `"tools": null`, …). Omitir el campo es válido en
  cualquier upstream OpenAI-compatible; mandarlo en `null` no lo es: Surplus
  Intelligence lo rechaza con un 400 que nombra los knobs ofensores
  (`max_tokens must be a number conforming to the specified constraints`,
  `tools must be an array`, `stop should not be null or undefined`), y el
  cliente ve un 400 que parece culpa del gateway por un body que no escribió.

  Verificado contra la API viva (2026-09-17): con los 12 knobs opcionales en
  `null` devuelve un solo 400 que los enumera a todos.

  Quitar esas claves es semánticamente neutro para knobs opcionales: ausente
  es el default documentado y el esquema de OpenAI no tiene ningún campo
  donde la diferencia entre `null` y ausente signifique algo.

  ## Solo el nivel superior, a propósito

  Los nils anidados NO se tocan. Dentro de `messages` un `null` SÍ significa
  algo: un turno de assistant que solo lleva `tool_calls` tiene
  `"content": null` por contrato, y borrar la clave cambia la forma del
  mensaje que un upstream estricto valida. Los knobs que los clientes
  serializan en null viven en el nivel superior, que es exactamente donde
  esto recorta.
  """

  @doc """
  Devuelve `payload` sin las claves de nivel superior cuyo valor es `nil`.

  Un payload que no sea mapa (no debería ocurrir) vuelve intacto.
  """
  @spec strip_nulls(term()) :: term()
  def strip_nulls(payload) when is_map(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def strip_nulls(payload), do: payload
end
