defmodule Tokengate.Notifications.Link do
  @moduledoc """
  A Telegram chat bound to a TokenGate user.

  Only a linked **admin** may drive the bot (Fase 2): the binding is what turns
  "someone wrote to the bot" into "an authorized operator". `chat_id` is unique,
  so a chat belongs to exactly one user.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "telegram_links" do
    field :chat_id, :string
    field :kind, :string, default: "chat"
    field :thread_id, :string
    field :telegram_username, :string
    field :label, :string

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(chat_id kind thread_id telegram_username label)a
  @required ~w(chat_id)a
  @kinds ~w(chat group channel)

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:chat_id, &String.trim/1)
    |> update_change(:thread_id, &normalize_thread/1)
    |> unique_constraint([:chat_id, :thread_id])
  end

  defp normalize_thread(nil), do: nil

  defp normalize_thread(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc "Valid destination kinds."
  def kinds, do: @kinds
end
