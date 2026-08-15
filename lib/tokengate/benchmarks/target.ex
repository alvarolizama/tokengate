defmodule Tokengate.Benchmarks.Target do
  @moduledoc """
  A benchmark target — one provider endpoint to test against.

  This is an ephemeral struct (no DB schema). The LiveView holds a list
  of these in socket assigns and the Runner fills in the `result` or
  `error` field after measurement.
  """

  defstruct [
    :id,
    :label,
    :base_url,
    :api_key,
    :model,
    :result,
    :error,
    :running?
  ]

  @doc "Creates a new target struct."
  def new(attrs) do
    %__MODULE__{
      id: generate_id(),
      label: attrs[:label] || attrs["label"] || "#{attrs[:model] || attrs["model"]}",
      base_url: attrs[:base_url] || attrs["base_url"],
      api_key: attrs[:api_key] || attrs["api_key"],
      model: attrs[:model] || attrs["model"],
      running?: false
    }
  end

  @doc "Marks a target as running."
  def running(target), do: %{target | running?: true, result: nil, error: nil}

  @doc "Fills in a successful result."
  def result(target, result_map) do
    %{target | running?: false, result: result_map, error: nil}
  end

  @doc "Fills in an error."
  def error(target, message) do
    %{target | running?: false, result: nil, error: message}
  end

  @doc "Returns true if the target has a result (success or error)."
  def done?(%{result: r, error: e}), do: not is_nil(r) or not is_nil(e)

  @doc "Returns true if the target completed successfully."
  def success?(%{result: r}), do: not is_nil(r)

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
