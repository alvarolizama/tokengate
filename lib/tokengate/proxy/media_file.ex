defmodule Tokengate.Proxy.MediaFile do
  @moduledoc """
  A file part of a multipart request, kept in memory.

  The stock `Plug.Parsers.MULTIPART` streams file parts to a temp file and
  exposes a `%Plug.Upload{}`; the proxy needs the raw bytes to forward the
  request untouched, so `TokengateWeb.Plugs.MediaBodyParser` describes the
  part with this struct instead. The bytes themselves live in the raw body
  stashed by the parser (`conn.private[:tokengate_raw_body]`) — duplicating
  them here would only cost memory.
  """

  @enforce_keys [:filename]
  defstruct [:filename, :content_type, :size]

  @type t :: %__MODULE__{
          filename: String.t(),
          content_type: String.t() | nil,
          size: non_neg_integer() | nil
        }
end
