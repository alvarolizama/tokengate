defmodule Tokengate.Routing.Strategy do
  @moduledoc """
  Behaviour for provider routing strategies.

  A strategy receives the list of candidate `Tokengate.Providers.ModelProvider`
  structs and an options map, and is responsible for selecting a single
  provider (or returning an error when none is available).

  ## Options

  Strategies never call the circuit breaker directly. Instead, the caller
  injects availability through the `:available?` predicate in `opts`:

    * `:api_key_hash`  – opaque binary identifying the API key (used for
      sticky / prompt-cache affinity). May be absent.
    * `:model_alias_id` – binary id of the model alias being routed. Used as
      part of the sticky key together with `:api_key_hash`.
    * `:available?` – `fn(model_provider) -> boolean`. Defaults to
      `fn _ -> true end`. The circuit breaker is injected here by the caller.

  ## Return value

    * `{:ok, %Tokengate.Providers.ModelProvider{}}` – the selected provider.
    * `{:error, :no_available_provider}` – no candidate satisfied the
      `available?` predicate.
  """

  @type candidate :: Tokengate.Providers.ModelProvider.t()

  @callback select(candidates :: [candidate()], opts :: map()) ::
              {:ok, candidate()} | {:error, :no_available_provider}
end
