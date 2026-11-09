defmodule TokengateWeb.EndpointOptionsTest do
  @moduledoc """
  Candado sobre las opciones de listener que **solo existen en prod**.

  `config/runtime.exs` arma `thousand_island_options` dentro del bloque
  `config_env() == :prod`, así que ni el suite ni el arranque en dev tocan ese
  camino: un bump de ThousandIsland que renombre una llave pasa inadvertido hasta
  el deploy — y ahí no falla un test, falla el contenedor en crash-loop
  (`Unsupported key(s) in thousand_island_options config`). Ya pasó una vez con
  `max_connections` → `num_connections` en la 1.6.

  Este test lee el archivo de config (texto, sin evaluarlo) y compara las llaves
  contra el struct que Bandit usa para validar.
  """

  use ExUnit.Case, async: true

  test "las llaves de thousand_island_options existen en el ServerConfig de ThousandIsland" do
    runtime = File.read!("config/runtime.exs")

    keys =
      Regex.scan(~r/thousand_island_options:\s*\[(.*?)\]/s, runtime)
      |> Enum.flat_map(fn [_, body] ->
        Regex.scan(~r/([a-z_]+):/, body) |> Enum.map(&List.last/1)
      end)
      |> Enum.map(&String.to_atom/1)
      |> Enum.uniq()

    assert keys != [],
           "no encontré `thousand_island_options` en config/runtime.exs — si se movió, " <>
             "actualiza este test para que siga cubriendo el camino de prod"

    valid = ThousandIsland.ServerConfig.__struct__() |> Map.from_struct() |> Map.keys()

    for key <- keys do
      assert key in valid,
             "#{inspect(key)} no existe en ThousandIsland.ServerConfig: Bandit rechaza el " <>
               "arranque del endpoint y la app no bootea. ¿Cambió el nombre en un bump de " <>
               "ThousandIsland? Llaves válidas: #{inspect(Enum.sort(valid))}"
    end
  end
end
