defmodule TokengateWeb.SessionHTML do
  @moduledoc """
  Renders templates for `TokengateWeb.SessionController`.

  Templates live in `session_html/*`.
  """

  use TokengateWeb, :html

  embed_templates "session_html/*"
end
