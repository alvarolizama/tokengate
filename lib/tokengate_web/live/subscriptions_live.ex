defmodule TokengateWeb.SubscriptionsLive do
  @moduledoc false
  use TokengateWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Subscripciones · Tokengate")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <.header>Subscripciones</.header>
      <p class="text-base-content/60">En construcción.</p>
    </Layouts.dashboard>
    """
  end
end
