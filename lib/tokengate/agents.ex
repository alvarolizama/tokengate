defmodule Tokengate.Agents do
  @moduledoc """
  Normalizes the raw client identity of a request into a canonical coding-agent
  name plus version, so monitoring and stats can group by "opencode v2",
  "Claude Code", "Hermes", "Pi", … instead of the raw HTTP `User-Agent`.

  The proxy stores two signals per request (`TokengateWeb.Plugs.ApiAuth`):

    * `agent_type`   — the explicit `X-Agent-Type` header (default "unknown").
    * `client_agent` — best human identity: `X-Title` → `User-Agent` →
      `X-Agent-Type` → "unknown".

  Clients do not reliably send `X-Agent-Type`, so identification parses the
  `User-Agent` product token. Known agents map to a friendly family; the major
  version splits families that behave differently across releases (opencode
  v1 vs v2). Unknown clients fall back to their product token (e.g. "curl",
  "node", "python-requests") so nothing is silently lumped into "unknown".

  Pure and side-effect free: it runs at read time over already-stored rows, so
  historical traffic is identified without any backfill or schema change.
  """

  @unknown "unknown"

  # Ordered family rules: first match wins. Each rule is {family, regex}. The
  # regex runs against the downcased identity; short names use a product-token
  # boundary (^|[ /;(]) so "pi" does not match "python" or "copilot".
  @rules [
    {"opencode", ~r/(?:^|[ \/;(])opencode(?:[\/ ]|$)/},
    {"Claude Code", ~r/claude[-_ ]?(?:code|cli)|claude-code|(?:^|[ \/;(])claude(?:[\/ ]|$)/},
    # Attribution URL (OpenRouter-style HTTP-Referer) as well as the product name.
    {"Hermes", ~r/hermes-agent\.nousresearch\.com|(?:^|[ \/;(])hermes(?:[\/ ]|$)/},
    {"Pi", ~r/(?:^|[ \/;(])pi(?:[\/ ]|$)/},
    {"Cursor", ~r/(?:^|[ \/;(])cursor(?:[\/ ]|$)/},
    {"Cline", ~r/(?:^|[ \/;(])cline(?:[\/ ]|$)/},
    {"Aider", ~r/(?:^|[ \/;(])aider(?:[\/ ]|$)/},
    {"Windsurf", ~r/(?:^|[ \/;(])windsurf(?:[\/ ]|$)/},
    {"Continue", ~r/(?:^|[ \/;(])continue(?:[\/ ]|$)/},
    {"Zed", ~r/(?:^|[ \/;(])zed(?:[\/ ]|$)/},
    {"Copilot", ~r/(?:^|[ \/;(])copilot(?:[\/ ]|$)/},
    {"Gemini CLI", ~r/gemini[-_ ]?cli|(?:^|[ \/;(])gemini(?:[\/ ]|$)/},
    {"Codex", ~r/(?:^|[ \/;(])codex(?:[\/ ]|$)/},
    {"Roo Code", ~r/roo[-_ ]?(?:code|cline)|(?:^|[ \/;(])roo(?:[\/ ]|$)/},
    {"Kilo Code", ~r/kilo[-_ ]?code|(?:^|[ \/;(])kilo(?:[\/ ]|$)/},
    {"Crush", ~r/(?:^|[ \/;(])crush(?:[\/ ]|$)/},
    {"Goose", ~r/(?:^|[ \/;(])goose(?:[\/ ]|$)/}
  ]

  @doc """
  Identifies the agent from the stored `client_agent` and `agent_type`.

  Returns `%{key: key, label: label, family: family, version: version}` where
  `key` is the stable grouping key (family + major version), `label` is the
  human name shown in the UI, `family` the agent family and `version` the major
  version string (or `nil`).

  ## Examples

      iex> Tokengate.Agents.identify("opencode/2.1.4", "unknown").label
      "opencode v2"

      iex> Tokengate.Agents.identify("opencode/0.5.1", "unknown").label
      "opencode v1"

      iex> Tokengate.Agents.identify("claude-cli/2.0.1 (external, cli)", "unknown").family
      "Claude Code"

      iex> Tokengate.Agents.identify("Hermes/1.0", "unknown").label
      "Hermes v1"

      iex> Tokengate.Agents.identify("pi/3.2", "unknown").family
      "Pi"

      iex> Tokengate.Agents.identify("python-requests/2.31", "unknown").family
      "python-requests"

      iex> Tokengate.Agents.identify("unknown", "unknown").label
      "unknown"

      iex> Tokengate.Agents.identify(nil, "opencode").family
      "opencode"
  """
  @spec identify(String.t() | nil, String.t() | nil) :: %{
          key: String.t(),
          label: String.t(),
          family: String.t(),
          version: String.t() | nil,
          icon: String.t(),
          logo: String.t() | nil
        }
  def identify(client_agent, agent_type) do
    identity = pick_identity(client_agent, agent_type)
    down = String.downcase(identity)

    case Enum.find(@rules, fn {_family, re} -> Regex.match?(re, down) end) do
      {family, _re} ->
        version = major_version(down, family)

        %{
          family: family,
          version: version,
          key: key(family, version),
          label: family_label(family, version),
          icon: icon_for(family),
          logo: logo_for(family)
        }

      nil ->
        family = product_token(identity)

        %{
          family: family,
          version: nil,
          key: family,
          label: family,
          icon: icon_for(family),
          logo: logo_for(family)
        }
    end
  end

  @doc "Convenience: the human label for a stored row's identity."
  @spec label(String.t() | nil, String.t() | nil) :: String.t()
  def label(client_agent, agent_type), do: identify(client_agent, agent_type).label

  @doc "Convenience: the hero icon name for a stored row's agent family."
  @spec icon(String.t() | nil, String.t() | nil) :: String.t()
  def icon(client_agent, agent_type), do: identify(client_agent, agent_type).icon

  # Hero icon per known family (the project renders icons via `<.icon name=...>`).
  # Generic glyphs, not brand logos; unknown families get a neutral chip.
  @icons %{
    "opencode" => "hero-code-bracket-square",
    "Claude Code" => "hero-sparkles",
    "Hermes" => "hero-paper-airplane",
    "Pi" => "hero-cpu-chip",
    "Cursor" => "hero-cursor-arrow-rays",
    "Cline" => "hero-command-line",
    "Aider" => "hero-wrench-screwdriver",
    "Windsurf" => "hero-flag",
    "Continue" => "hero-arrow-path",
    "Zed" => "hero-bolt",
    "Copilot" => "hero-user-circle",
    "Gemini CLI" => "hero-sparkles",
    "Codex" => "hero-book-open",
    "Roo Code" => "hero-code-bracket",
    "Kilo Code" => "hero-code-bracket",
    "Crush" => "hero-fire",
    "Goose" => "hero-paper-airplane"
  }
  @default_icon "hero-cpu-chip"

  defp icon_for(family), do: Map.get(@icons, family, @default_icon)

  # Real brand logos downloaded to priv/static/images/agents (served by
  # Plug.Static, "images" is in static_paths). Families without a trustworthy
  # brand asset return nil and the UI falls back to the hero `icon`.
  @logos %{
    "opencode" => "/images/agents/opencode.svg",
    "Claude Code" => "/images/agents/claude.svg",
    "Cursor" => "/images/agents/cursor.svg",
    "Cline" => "/images/agents/cline.svg",
    "Windsurf" => "/images/agents/windsurf.svg",
    "Zed" => "/images/agents/zed.svg",
    "Copilot" => "/images/agents/copilot.svg",
    "Gemini CLI" => "/images/agents/gemini.svg",
    "Codex" => "/images/agents/codex.svg",
    "Pi" => "/images/agents/pi.svg",
    "Hermes" => "/images/agents/hermes.svg",
    "Aider" => "/images/agents/aider.svg"
  }

  defp logo_for(family), do: Map.get(@logos, family)

  @doc "Convenience: the brand logo path for a row's agent, or nil (use hero icon)."
  @spec logo(String.t() | nil, String.t() | nil) :: String.t() | nil
  def logo(client_agent, agent_type), do: identify(client_agent, agent_type).logo

  # Prefer the explicit X-Agent-Type when it carries a real value; otherwise the
  # human identity (X-Title/User-Agent). "unknown" placeholders never win.
  defp pick_identity(client_agent, agent_type) do
    cond do
      present?(agent_type) and agent_type != @unknown -> agent_type
      present?(client_agent) and client_agent != @unknown -> client_agent
      present?(agent_type) -> agent_type
      present?(client_agent) -> client_agent
      true -> @unknown
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  # Major version: the first integer after the family token (opencode/2.1 -> 2).
  # Families pinned to a major by the operator (opencode v1 = 0.x) keep that
  # convention: opencode 0.x is "v1", >=1 is "v2"+ by major.
  defp major_version(down, "opencode") do
    case Regex.run(~r/opencode[\/ ]v?(\d+)/, down) do
      [_, "0"] -> "1"
      [_, major] -> major
      _ -> nil
    end
  end

  defp major_version(down, family) do
    token = family |> String.downcase() |> String.split(" ") |> hd()

    case Regex.run(~r/#{Regex.escape(token)}[\/ ]v?(\d+)/, down) do
      [_, major] -> major
      _ -> nil
    end
  end

  defp key(family, nil), do: family
  defp key(family, version), do: family <> "|" <> version

  defp family_label(family, nil), do: family
  defp family_label(family, version), do: family <> " v" <> version

  # Fallback: the first product token of a User-Agent ("curl/8.1" -> "curl",
  # "Mozilla/5.0 (...)" -> "Mozilla"). Empty/unknown stays "unknown".
  defp product_token(identity) do
    trimmed = String.trim(identity)

    cond do
      trimmed == "" or trimmed == @unknown ->
        @unknown

      true ->
        token =
          trimmed
          |> String.split(~r/[\/ ]/, parts: 2)
          |> hd()
          |> String.trim()

        if token == "", do: @unknown, else: token
    end
  end
end
