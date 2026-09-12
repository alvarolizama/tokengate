defmodule Tokengate.Providers.Catalog do
  @moduledoc """
  Compile-time catalog of builtin providers.

  A provider's identity is code, not user data: its base URL, API dialect
  and capabilities belong in the repo, released with the app. The database
  only stores what the user contributes (credentials) and their relations
  (aliases, routing, pricing). Custom providers created by operators are
  first-class rows with `source: "custom"` and the same contract.

  ## Dialects

    * `"openai"` — OpenAI-compatible: chat at `{base}/chat/completions`,
      models at `{base}/models`, embeddings at `{base}/embeddings`.
    * `"openrouter"` — same surface, but embedding models are listed at
      `{base}/embeddings/models`.

  ## Catalog rule

  Only providers that serve `/embeddings` under the SAME base path as chat
  carry the `embedding` capability. Providers with a separate embedding
  surface are LLM-only (use a custom provider if really needed).

  The boot-time sync (`Tokengate.Providers.CatalogSync`) upserts every
  builtin entry by `key` and never touches `custom` rows.
  """

  @dialects ~w(openai openrouter)
  @sources ~w(builtin custom)
  @capabilities ~w(llm embedding)
  # Billing surfaces: subscription plans (flat rate, rate-limited) vs
  # pay-per-token. Customs are their own group in the UI.
  @billing_modes ~w(subscription pay_per_token)

  @builtin [
    %{
      key: "openrouter",
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      dialect: "openrouter",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "fireworks",
      name: "Fireworks AI",
      base_url: "https://api.fireworks.ai/inference/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "qwen_cloud",
      name: "Qwen Cloud",
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm", "embedding"]
    },
    %{
      key: "qwen_cloud_token_plan",
      name: "Qwen Cloud (Token Plan)",
      base_url: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "opencode_zen",
      name: "OpenCode Zen",
      base_url: "https://opencode.ai/zen/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "opencode_go",
      name: "OpenCode Go",
      base_url: "https://opencode.ai/zen/go/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "kimi",
      name: "Kimi (Moonshot)",
      base_url: "https://api.moonshot.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "kimi_code",
      name: "Kimi Code (suscripción)",
      base_url: "https://api.kimi.com/coding/v1",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "zai",
      name: "Z.AI",
      base_url: "https://api.z.ai/api/paas/v4",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "zai_coding_plan",
      name: "Z.AI (GLM Coding Plan)",
      base_url: "https://api.z.ai/api/coding/paas/v4",
      dialect: "openai",
      billing: "subscription",
      capabilities: ["llm"]
    },
    %{
      key: "abliteration",
      name: "Abliteration",
      base_url: "https://api.abliteration.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "crof_ai",
      name: "CrofAi",
      base_url: "https://crof.ai/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    },
    %{
      key: "nube",
      name: "Nube",
      base_url: "https://ai.nube.sh/api/v1",
      dialect: "openai",
      billing: "pay_per_token",
      capabilities: ["llm"]
    }
  ]

  @doc "All builtin catalog entries."
  @spec all() :: [map()]
  def all, do: @builtin

  @doc "Fetches a builtin entry by key."
  @spec get(String.t()) :: map() | nil
  def get(key) when is_binary(key), do: Enum.find(@builtin, &(&1.key == key))

  @doc "Builtin entries that declare the given capability."
  @spec by_capability(String.t()) :: [map()]
  def by_capability(capability) when is_binary(capability),
    do: Enum.filter(@builtin, &(capability in &1.capabilities))

  @doc "Valid dialects."
  def dialects, do: @dialects

  @doc "Valid sources."
  def sources, do: @sources

  @doc "Valid capabilities."
  def capabilities, do: @capabilities

  @doc "Valid billing surfaces."
  def billing_modes, do: @billing_modes

  @doc """
  Builtin entries grouped for UI display: subscription plans first
  (better economics), then pay-per-token. Customs are a separate group
  rendered by the caller.
  """
  @spec grouped() :: %{subscription: [map()], pay_per_token: [map()]}
  def grouped do
    @builtin
    |> Enum.group_by(& &1.billing)
    |> Map.put_new("subscription", [])
    |> Map.put_new("pay_per_token", [])
    |> then(&%{subscription: &1["subscription"], pay_per_token: &1["pay_per_token"]})
  end

  @doc """
  Normalizes a base URL for catalog matching: trailing slash trimmed,
  host downcased. `https://OpenRouter.ai/api/v1/` and
  `https://openrouter.ai/api/v1` match.
  """
  @spec normalize_base_url(nil | String.t()) :: nil | String.t()
  def normalize_base_url(nil), do: nil

  def normalize_base_url(url) when is_binary(url) do
    url |> String.trim_trailing("/") |> String.downcase()
  end

  @doc """
  Finds the builtin entry whose base_url matches the given URL
  (normalized). Returns the entry map or nil.
  """
  @spec match_by_base_url(nil | String.t()) :: map() | nil
  def match_by_base_url(nil), do: nil

  def match_by_base_url(base_url) do
    normalized = normalize_base_url(base_url)
    Enum.find(@builtin, &(normalize_base_url(&1.base_url) == normalized))
  end

  @doc """
  True when a raw provider row's `embedding_base_url` override, if any,
  differs from the default `{base_url}/embeddings` path. Rows that do
  (possible in production) would change behaviour when the override column
  is dropped — the migration surfaces them instead of silently breaking.
  Takes a plain map (raw DB row), not a schema struct.
  """
  @spec embedding_override_conflict?(map()) :: boolean()
  def embedding_override_conflict?(row) when is_map(row) do
    case Map.get(row, :embedding_base_url) do
      nil ->
        false

      "" ->
        false

      override ->
        base = Map.get(row, :base_url) || ""
        normalize_base_url(override) != normalize_base_url(base <> "/embeddings")
    end
  end
end
