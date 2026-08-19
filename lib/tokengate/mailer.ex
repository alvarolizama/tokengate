defmodule Tokengate.Mailer do
  @moduledoc """
  The application's mailer. Uses `Swoosh.Mailer` with the adapter configured
  for the `:tokengate` OTP app (Local by default, Test in test env).
  """
  use Swoosh.Mailer, otp_app: :tokengate
end
