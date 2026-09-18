defmodule Tokengate.Notifications.Events do
  @moduledoc """
  Catálogo de eventos notificables.

  Cada evento declara su `severity`, si va **habilitado por defecto**, su
  **cooldown** (la ventana anti-repetición, en ms) y la etiqueta/entidad con la
  que se presenta. Este módulo es la única autoridad sobre:

    * qué eventos existen,
    * a qué evento de catálogo corresponde una acción de auditoría
      (`from_audit_action/1`) — así los enganches de la sección de admin se
      resuelven con un mapa y no con call sites repartidos,
    * cómo se convierte un evento en texto para Telegram (`message/2`).
  """

  @type name :: atom()

  # Orden de severidad, de más a menos urgente.
  @severities ~w(critical warning info security)

  @events %{
    credential_disabled: %{
      severity: "critical",
      default_enabled: true,
      cooldown_ms: 300_000,
      label: "Provider credential disabled",
      entity_type: "credential"
    },
    global_daily_cap_reached: %{
      severity: "critical",
      default_enabled: true,
      cooldown_ms: 6 * 60 * 60 * 1000,
      label: "Global daily cap reached",
      entity_type: "global_settings"
    },
    breaker_opened: %{
      severity: "warning",
      default_enabled: true,
      cooldown_ms: 300_000,
      label: "Circuit breaker opened",
      entity_type: "credential"
    },
    subject_limit_reached: %{
      severity: "warning",
      default_enabled: true,
      cooldown_ms: 60 * 60 * 1000,
      label: "Monthly limit reached",
      entity_type: "subject"
    },
    no_credit: %{
      severity: "warning",
      default_enabled: true,
      cooldown_ms: 60 * 60 * 1000,
      label: "No spending path",
      entity_type: "subject"
    },
    topup_changed: %{
      severity: "info",
      default_enabled: true,
      cooldown_ms: 0,
      label: "Top-up changed",
      entity_type: "topup"
    },
    credential_reactivated: %{
      severity: "info",
      default_enabled: true,
      cooldown_ms: 0,
      label: "Provider credential reactivated",
      entity_type: "credential"
    },
    user_created: %{
      severity: "info",
      default_enabled: false,
      cooldown_ms: 0,
      label: "User created",
      entity_type: "user"
    },
    service_created: %{
      severity: "info",
      default_enabled: false,
      cooldown_ms: 0,
      label: "Service created",
      entity_type: "service"
    },
    api_key_changed: %{
      severity: "info",
      default_enabled: false,
      cooldown_ms: 0,
      label: "API key changed",
      entity_type: "api_key"
    },
    impersonation_started: %{
      severity: "security",
      default_enabled: false,
      cooldown_ms: 0,
      label: "Impersonation started",
      entity_type: "user"
    }
  }

  # Acción de auditoría → evento de catálogo. Cualquier acción que no figure
  # aquí simplemente no notifica.
  @audit_map %{
    "topup.create" => :topup_changed,
    "topup.revoke" => :topup_changed,
    "topup.toggle_status" => :topup_changed,
    "credential.reactivate" => :credential_reactivated,
    "user.create" => :user_created,
    "service.create" => :service_created,
    "api_key.create" => :api_key_changed,
    "api_key.revoke" => :api_key_changed,
    "impersonate.start" => :impersonation_started
  }

  @doc "All event names as atoms."
  @spec names() :: [name()]
  def names, do: Map.keys(@events)

  @doc "All event names as strings, in catalog order."
  @spec names_as_strings() :: [String.t()]
  def names_as_strings, do: Enum.map(@events, fn {name, _} -> Atom.to_string(name) end)

  @doc "The event spec, or `:error` for an unknown name."
  @spec fetch(name()) :: {:ok, map()} | :error
  def fetch(name) when is_atom(name) do
    case Map.fetch(@events, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> :error
    end
  end

  def fetch(_), do: :error

  @doc "Severity of an event (`\"info\"` when unknown)."
  @spec severity(name()) :: String.t()
  def severity(name) do
    case fetch(name) do
      {:ok, %{severity: s}} -> s
      :error -> "info"
    end
  end

  @doc "Default enabled flag of an event (`false` when unknown)."
  @spec default_enabled?(name()) :: boolean()
  def default_enabled?(name) do
    case fetch(name) do
      {:ok, %{default_enabled: v}} -> v
      :error -> false
    end
  end

  @doc "Anti-repetition window in ms (`0` = no throttle)."
  @spec cooldown_ms(name()) :: non_neg_integer()
  def cooldown_ms(name) do
    case fetch(name) do
      {:ok, %{cooldown_ms: ms}} -> ms
      :error -> 0
    end
  end

  @doc "Human label of an event, in the catalog's source language."
  @spec label(name()) :: String.t()
  def label(name) do
    case fetch(name) do
      {:ok, %{label: label}} -> label
      :error -> "Notification"
    end
  end

  @doc "Severity ordering, most urgent first."
  def severities, do: @severities

  @doc """
  Maps an audit action to its catalog event, or `nil` when the action does not
  notify. This is what keeps the audit hook declarative.
  """
  @spec from_audit_action(String.t() | nil) :: name() | nil
  def from_audit_action(action) when is_binary(action), do: Map.get(@audit_map, action)
  def from_audit_action(_), do: nil

  @doc """
  Renders the Telegram message for an event.

  Returns `{title, body}` where `body` is a short detail block (may be empty).
  The message carries **only** ids, labels, prefixes and amounts — never a
  secret value.
  """
  @spec message(name(), map()) :: {String.t(), String.t()}
  def message(event, attrs) do
    {label(event), details(event, attrs)}
  end

  defp details(:credential_disabled, attrs) do
    join_lines([
      value_line("Credential", fetch(attrs, :target_label)),
      value_line("Reason", fetch(attrs, :reason))
    ])
  end

  defp details(:breaker_opened, attrs) do
    join_lines([
      value_line("Credential", fetch(attrs, :target_label)),
      value_line("Reason", fetch(attrs, :reason))
    ])
  end

  defp details(:global_daily_cap_reached, attrs) do
    join_lines([
      value_line("Cap", fetch(attrs, :limit_usd)),
      value_line("Spent", fetch(attrs, :spent_usd))
    ])
  end

  defp details(event, attrs)
       when event in [
              :subject_limit_reached,
              :no_credit,
              :topup_changed,
              :user_created,
              :service_created,
              :api_key_changed,
              :impersonation_started,
              :credential_reactivated
            ] do
    join_lines([
      value_line("Subject", fetch(attrs, :target_label)),
      value_line("Amount", fetch(attrs, :amount_usd)),
      value_line("Status", fetch(attrs, :status))
    ])
  end

  defp details(_event, attrs),
    do: join_lines([value_line("Subject", fetch(attrs, :target_label))])

  defp fetch(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp fetch(_attrs, _key), do: nil

  defp value_line(_key, nil), do: nil
  defp value_line(_key, ""), do: nil
  defp value_line(key, value), do: "#{key}: #{to_string(value)}"

  defp join_lines(lines) do
    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
