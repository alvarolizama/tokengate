import Ecto.Migration

defmodule Tokengate.Repo.Migrations.AddDecisionModelType do
  @moduledoc """
  `decision` — TypeSafe's System One models (Jev): typed decisions with
  calibrated probabilities instead of generated text. Served by the chat
  endpoint (`/v1/chat/completions`) through the typesafe dialect adapter,
  so chat routes accept `llm | decision`.
  """
  use Ecto.Migration

  @all ~w(llm embedding decision rerank stt tts image video music)
  @previous ~w(llm embedding rerank stt tts image video music)
  @constraint "models_model_type_check"

  def up do
    execute(
      """
      ALTER TABLE models DROP CONSTRAINT #{@constraint};
      """,
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@constraint}
      CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@previous)}])::text[])));
      """
    )

    execute(
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@constraint}
      CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@all)}])::text[])));
      """,
      """
      ALTER TABLE models DROP CONSTRAINT #{@constraint};
      """
    )
  end

  defp quoted(types) do
    types
    |> Enum.map(&"'#{&1}'::character varying")
    |> Enum.join(", ")
  end
end
