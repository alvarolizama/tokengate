defmodule Tokengate.Proxy.Decisions do
  @moduledoc """
  The decisions service: one public contract, two wire shapes.

  `post/4` is the adapter_fun behind `POST /v1/decisions`. The provider's
  `decisions_shape` (Catalog) picks the wire:

    * `:openai` (default) — the request IS the wire: passthrough to
      `{base}` + the path `ProviderPaths` resolves for `:decisions`
      (OpenAI, Fireworks, an oMLX host, Vercel AI Gateway…).
    * `:systemone` — the request translates through
      `Tokengate.Proxy.DecisionsTranslator` and posts to the provider's
      System One endpoint (TypeSafe's `/systemone`, OpenRouter's absolute
      alpha URL…). One translation covers every Jev reseller: they all
      speak the same envelope.

  Error classification stays in `ProviderAdapter` via `OpenAIAdapter`, so
  the fallback matrix treats a decisions attempt like any other service.

  NOTE: `post/4` bypasses `ProviderAdapter.dispatch/1` on purpose — the
  decisions surface has ONE implementation for every OpenAI-dialect provider
  (the path is all that varies, and `ProviderPaths` owns it) and ONE
  translator for every System One speaker. The day a dialect needs its own
  decisions wire, this is the module that grows the branch — and the two
  knobs it reads are `Catalog.decisions_shape/1` and `ProviderPaths`.
  """

  alias Tokengate.Proxy.{DecisionsTranslator, OpenAIAdapter}
  alias Tokengate.Providers.Catalog

  @doc """
  POSTs one decisions request upstream, translating when the provider's
  wire is System One. Same result tuples as `OpenAIAdapter.service_post/5`.
  """
  @spec post(map(), map(), map(), keyword()) ::
          {:ok, map(), latency_ms :: non_neg_integer(),
           resp_headers :: [{String.t(), String.t()}]}
          | {:error, Tokengate.Proxy.ProviderAdapter.failure_reason(),
             status :: non_neg_integer() | nil, error_message :: String.t() | nil}
  def post(provider, credential, payload, opts) do
    if systemone_shape?(provider) do
      DecisionsTranslator.post_systemone(provider, credential, payload, opts)
    else
      OpenAIAdapter.service_post(provider, credential, :decisions, payload, opts)
    end
  end

  # Identity is the provider's key (models.dev id or the custom's own):
  # shape is code, not row data.
  defp systemone_shape?(provider) do
    key = Map.get(provider, :key) || Map.get(provider, "key")
    Catalog.decisions_shape(key) == :systemone
  end
end
