defmodule TokengateWeb.PageController do
  use TokengateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
