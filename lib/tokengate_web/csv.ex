defmodule TokengateWeb.CSV do
  @moduledoc """
  Escritura de CSV: **un solo** escape para todo el proyecto.

  `escape/1` cubre las dos cosas que rompen un CSV abierto en Excel o Sheets:

    * **delimitadores** — comas, comillas y saltos de línea (RFC 4180);
    * **fórmulas** — un campo que empieza con `=`, `+`, `-`, `@`, tab o CR lo
      interpreta el spreadsheet como fórmula y lo evalúa al abrir el archivo.
      Varios de los campos que exportamos son texto que manda el cliente
      (`user_agent`, `origin`, `error_message`, `client_agent`), así que se
      prefija con apóstrofo para forzar el render como texto.

  Que viva aquí y no copiado en cada controller es a propósito: el export de
  auditoría se quedó sin el guard de fórmula justo por tener su propia copia
  (hallazgo Medio 6 de la auditoría 2026-11-08), mientras su gemelo de stats sí
  lo tenía. Una implementación, dos consumidores.
  """

  @formula_starters ["=", "+", "-", "@", "\t", "\r"]

  @doc """
  Escapa un valor para una celda CSV.

  `nil` se exporta como celda vacía; todo lo demás pasa por `to_string/1`, así
  que sirve igual para un entero de status que para un decimal ya formateado.
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> neutralize_formula()
    |> quote_if_needed()
  end

  # Formula injection guard: se marca la celda como texto antes de citarla, no
  # después — el apóstrofo tiene que quedar DENTRO de las comillas para que el
  # spreadsheet lo lea como parte del valor.
  defp neutralize_formula(value) do
    if String.starts_with?(value, @formula_starters) do
      "'" <> value
    else
      value
    end
  end

  defp quote_if_needed(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
