# Production seed — the OPTIONAL admin bootstrap.
#
# Evaluated by `Tokengate.Release.seed/0`, which `docker/entrypoint.sh` runs on
# every container boot via `Tokengate.Release.setup/0`. Two consequences:
#
#   1. It MUST stay idempotent (it runs on every deploy, not once).
#   2. It MUST NOT create demo data. Everything else under priv/repo/ is
#      development-only: `seeds.exs` (local demo dataset, `mix ecto.setup`) and
#      `demo_seeds.exs` (`mix ecto.demo`). Both create users whose password is
#      public in this repository.
#
# Setting TOKENGATE_ADMIN_PASSWORD is the opt-in: with it the boot creates the
# admin, so an unattended deploy (or an instance that is already public) is
# claimed from the start. Without it NOTHING is created — the instance boots
# with zero users and `/` sends the owner to `/onboarding`, where the first
# account created becomes the global admin. That is the default on purpose:
# falling back to a password hardcoded in a public repository is exactly how a
# production instance ends up with a known-credential admin.
#
# TOKENGATE_ADMIN_EMAIL defaults to admin@tokengate.local. An existing admin is
# left untouched: this never resets a password.

alias Tokengate.Accounts

admin_email = System.get_env("TOKENGATE_ADMIN_EMAIL") || "admin@tokengate.local"
admin_password = System.get_env("TOKENGATE_ADMIN_PASSWORD")

cond do
  admin_password in [nil, ""] ->
    IO.puts("""
    [seeds_prod] TOKENGATE_ADMIN_PASSWORD is not set — no admin created.

      The instance keeps whatever users it has (a fresh one boots with none)
      and `/` sends the visitor to /onboarding, where the first account
      becomes the global admin. Set TOKENGATE_ADMIN_PASSWORD (and optionally
      TOKENGATE_ADMIN_EMAIL) to bootstrap the admin from here instead.
    """)

  (existing = Accounts.get_user_by_email(admin_email)) ->
    IO.puts("[seeds_prod] admin user #{existing.email} already exists — left untouched")

  true ->
    {:ok, user} =
      Accounts.admin_create_user(%{
        email: admin_email,
        name: "Admin",
        password: admin_password,
        global_role: "admin",
        status: "active"
      })

    IO.puts("[seeds_prod] seeded admin user: #{user.email}")
end
