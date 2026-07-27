defmodule TokengateWeb.Presence do
  @moduledoc """
  Tracks connected dashboard users in real time via Phoenix.Presence.

  LiveViews `track/3` their process on the `"dashboard:online"` topic keyed
  by user id; subscribers receive `presence_diff` broadcasts and can list
  who's online with `list_online/0`.
  """

  use Phoenix.Presence,
    otp_app: :tokengate,
    pubsub_server: Tokengate.PubSub

  @topic "dashboard:online"

  def topic, do: @topic

  @doc "Track the current LiveView process as online for `user`."
  def track_user(pid, user) do
    track(pid, @topic, user.id, %{
      email: user.email,
      online_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "List of currently online users: [%{id, email}], one entry per user."
  def list_online do
    @topic
    |> list()
    |> Enum.map(fn {user_id, %{metas: [meta | _]}} ->
      %{id: user_id, email: meta.email}
    end)
    |> Enum.sort_by(& &1.email)
  end
end
