# Seeds for development. Creates one admin user.
#
# Run with: mix run priv/repo/seeds.exs (also part of `mix ecto.setup`)
#
# The admin password can be overridden with TOKENGATE_ADMIN_PASSWORD.
# This seed is idempotent — it won't duplicate the user on re-run.

alias Tokengate.Accounts

admin_email = System.get_env("TOKENGATE_ADMIN_EMAIL") || "admin@tokengate.local"
admin_password = System.get_env("TOKENGATE_ADMIN_PASSWORD") || "tokengate-admin-secret-1"

case Accounts.get_user_by_email(admin_email) do
  nil ->
    {:ok, user} =
      Accounts.register_user(%{
        email: admin_email,
        name: "Admin",
        password: admin_password,
        global_role: "admin"
      })

    IO.puts("Seeded admin user: #{user.email}")

  _user ->
    IO.puts("Admin user #{admin_email} already exists")
end
