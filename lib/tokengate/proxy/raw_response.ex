defmodule Tokengate.Proxy.RawResponse do
  @moduledoc """
  A non-JSON 2xx response from an upstream service, kept byte-for-byte.

  The six path-routed services answer with shapes that are not JSON for
  some upstreams — `audio/mpeg` from tts, image/video assets, plain text —
  and `json/1` cannot send them. The adapter returns this struct instead of
  degrading the body to `%{}` (the old `decode!/1` behaviour), and
  `ProxyController` writes the bytes back with the upstream's own
  content-type.
  """

  @enforce_keys [:body]
  defstruct [:body, :content_type]

  @type t :: %__MODULE__{
          body: binary(),
          content_type: String.t() | nil
        }
end
