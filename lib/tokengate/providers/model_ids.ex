defmodule Tokengate.Providers.ModelIds do
  @moduledoc """
  El id de un modelo tal como el upstream lo publica: su nombre corto, el lab de
  su prefijo y su tipo por la familia del id.

  Es la mitad que SOBREVIVE del antiguo `ModelIds`: el espejo de modelos de
  models.dev se retiró (el alta lista los modelos del proveedor en vivo con su
  API key), pero tres hechos sobre el ID siguen usándose y no dependen de
  ninguna tabla:

    * `short_name/1` — el nombre por defecto de un modelo y el id que viaja al
      upstream para un proveedor de ids PELADOS (`zai/glm-5.3` → `glm-5.3`).
    * `lab_key/1` — el lab al que pertenece un id (`lab/modelo`), que es el
      vínculo blando con `labs` y de donde sale la marca del modelo.
    * `model_type_hint/1` — el tipo que el id sugiere cuando ningún patrón de
      `ServiceModels` lo clasifica.

  models.dev no publica ni el tipo ni una lista de ids servibles: el tipo es
  siempre una PISTA que el operador confirma en el formulario, y la lista real
  sale del propio proveedor.
  """

  # models.dev does not distinguish an embedding from a chat model. The id is
  # the only signal upstream publishes, and this gateway only ever needs a HINT:
  # it prefills `model_type` in the form and the operator confirms it.
  @embedding_hint ~r/(^|[-_\/])embed/i

  # What a lab id looks like (models.dev lab ids are lowercase slugs, and the
  # `labs` table pins the same shape). A first segment that fails this is an
  # account or a namespace, not a lab.
  @lab_id_format ~r/^[a-z0-9][a-z0-9._-]*$/

  @doc """
  Default operator-facing name for a provider-published model id.

  It strips the lab prefix of a canonical id (`lab/model`), and for an id only a
  provider publishes — a path of its own, like
  `accounts/fireworks/routers/kimi-latest` — it keeps the last segment, which is
  the part that names the model. The operator edits it in the form anyway: this
  is a default, not a decision.

      iex> Tokengate.Providers.ModelIds.short_name("openai/gpt-5-nano")
      "gpt-5-nano"

      iex> Tokengate.Providers.ModelIds.short_name("glm-5.2")
      "glm-5.2"

      iex> Tokengate.Providers.ModelIds.short_name("accounts/fireworks/routers/kimi-latest")
      "kimi-latest"
  """
  @spec short_name(String.t()) :: String.t()
  def short_name(id) when is_binary(id) do
    case String.split(id, "/") do
      [lab, model] -> if plausible_lab?(lab) and model != "", do: model, else: id
      [_ | _] = parts -> if length(parts) > 2, do: List.last(parts), else: id
      [] -> id
    end
  end

  def short_name(id), do: to_string(id)

  @doc """
  The lab a model id belongs to (nil when the id is not `lab/model`).

  A lab IS the prefix of a canonical id — that is how `labs` is derived — so the
  prefix only counts when the id is exactly `lab/model` and the prefix looks like
  a lab id. An id a provider publishes can carry a path of its own
  (`accounts/fireworks/routers/kimi-latest`, `@cf/meta/llama-…`) whose first
  segment is an account or a namespace: attributing that model to a lab nobody
  publishes would be a lie, and there is no `labs` row to hang it on either.

      iex> Tokengate.Providers.ModelIds.lab_key("anthropic/claude-opus-4.7")
      "anthropic"

      iex> Tokengate.Providers.ModelIds.lab_key("accounts/fireworks/routers/kimi-latest")
      nil
  """
  @spec lab_key(String.t() | nil) :: String.t() | nil
  def lab_key(id) when is_binary(id) do
    case String.split(id, "/") do
      [lab, model] -> if model != "" and plausible_lab?(lab), do: lab
      _ -> nil
    end
  end

  def lab_key(_), do: nil

  @doc """
  HINT for `models.model_type` based on the id: `"embedding"`, `"decision"`
  or `"llm"`.

  Es el ÚLTIMO recurso de la clasificación: los seis servicios de media salen de
  los patrones de `ServiceModels`, y aquí sólo se distingue lo que un id
  delata — un embedding, un modelo de decisiones de TypeSafe, o chat.

      iex> Tokengate.Providers.ModelIds.model_type_hint("google/gemini-embedding-001")
      "embedding"

      iex> Tokengate.Providers.ModelIds.model_type_hint("typesafe/jev")
      "decision"

      iex> Tokengate.Providers.ModelIds.model_type_hint("openai/gpt-5-nano")
      "llm"
  """
  @spec model_type_hint(String.t()) :: String.t()
  def model_type_hint(id) when is_binary(id) do
    cond do
      Regex.match?(@embedding_hint, id) -> "embedding"
      String.starts_with?(id, "typesafe/") -> "decision"
      true -> "llm"
    end
  end

  def model_type_hint(_), do: "llm"

  defp plausible_lab?(lab), do: Regex.match?(@lab_id_format, lab)
end
