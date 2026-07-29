defmodule TokengateWeb.PageController do
  use TokengateWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/dashboard")
    else
      redirect(conn, to: "/login")
    end
  end
end
