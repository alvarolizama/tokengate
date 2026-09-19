# Seeds for development. Creates one admin user plus a full demo dataset:
# users, groups, a service, topups, models of every type, provider
# credentials (DUMMY keys), model grants and proxy API keys.
#
# DEV ONLY — never runs in production (see the guard below). Production boots
# evaluate priv/repo/seeds_prod.exs instead (admin user only).
#
# Run with: mix run priv/repo/seeds.exs (also part of `mix ecto.setup`)
#
# The admin credentials can be overridden with TOKENGATE_ADMIN_EMAIL /
# TOKENGATE_ADMIN_PASSWORD. Everything is idempotent — looked up by natural
# key before inserting, so re-running never duplicates.
#
# DANGER: the provider API keys here are PLACEHOLDERS (sk-seed-...). Requests
# through them will fail upstream auth. Replace them from the Providers page.

# ---------------------------------------------------------------------------
# GUARD — this file is DEVELOPMENT ONLY and must never run in production.
# ---------------------------------------------------------------------------
# `Tokengate.Release.seed/0` evals a seed file on EVERY prod container boot
# (docker/entrypoint.sh → Tokengate.Release.setup/0). It used to point at THIS
# file, which silently created the demo users below — including
# dev@tokengate.local / tester@tokengate.local with the password hardcoded a
# few lines down — in production. It now evals priv/repo/seeds_prod.exs.
#
# This guard makes a regression abort the boot loudly instead of seeding demo
# data into prod. The discriminator is `:code.is_loaded(Mix)`: the Mix CLI is
# running in `mix run` / `mix ecto.setup`, and nothing in the release ever
# loads Mix (it ships no mix.beam). Do NOT use `Code.ensure_loaded?/1` here —
# it answers "is Mix reachable in the code path", which is true in a plain
# `elixir` shell on a normal install, so the guard would never fire.
if :code.is_loaded(Mix) == false and System.get_env("TOKENGATE_ALLOW_DEMO_SEEDS") != "1" do
  raise """
  priv/repo/seeds.exs is the DEVELOPMENT demo dataset and refuses to run
  without Mix (i.e. inside a release).

  It creates demo users whose password is public in this repository. For a
  production boot use priv/repo/seeds_prod.exs, which
  Tokengate.Release.seed/0 already evaluates.

  Override deliberately (only on a throwaway database):
    TOKENGATE_ALLOW_DEMO_SEEDS=1 bin/tokengate eval "Code.eval_file(\\"priv/repo/seeds.exs\\")"
  """
end

alias Tokengate.Accounts
alias Tokengate.Credits.Topups
alias Tokengate.Repo
alias Tokengate.Providers

# ---------------------------------------------------------------------------
# Admin + demo users
# ---------------------------------------------------------------------------

admin_email = System.get_env("TOKENGATE_ADMIN_EMAIL") || "admin@tokengate.local"
admin_password = System.get_env("TOKENGATE_ADMIN_PASSWORD") || "tokengate-admin-secret-1"
demo_password = "tokengate-demo-secret-1"

admin =
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
      user

    user ->
      IO.puts("Admin user #{admin_email} already exists")
      user
  end

# demo users — one plain member, one with spend limit
demo_users = %{
  "dev@tokengate.local" => %{
    name: "Dev User",
    monthly_spend_limit_usd: Decimal.new("25.00"),
    default_rpm_limit: 60
  },
  "tester@tokengate.local" => %{
    name: "Tester",
    monthly_spend_limit_usd: nil,
    default_rpm_limit: nil
  }
}

users =
  Map.new(demo_users, fn {email, attrs} ->
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            email: email,
            name: attrs.name,
            password: demo_password,
            global_role: "user",
            monthly_spend_limit_usd: attrs.monthly_spend_limit_usd,
            default_rpm_limit: attrs.default_rpm_limit
          })

        IO.puts("Seeded demo user: #{user.email}")
        {email, user}

      user ->
        {email, user}
    end
  end)

dev_user = users["dev@tokengate.local"]
tester_user = users["tester@tokengate.local"]

# ---------------------------------------------------------------------------
# Groups + membership
# ---------------------------------------------------------------------------

seed_group = fn name, description ->
  case Repo.get_by(Tokengate.Accounts.Group, name: name) do
    nil ->
      {:ok, group} = Accounts.create_group(%{name: name, description: description})
      IO.puts("Seeded group: #{group.name}")
      group

    group ->
      group
  end
end

dev_group = seed_group.("devs", "Equipo de desarrollo — acceso a todos los modelos de chat")
qa_group = seed_group.("qa", "QA — solo modelos de embedding para pruebas")

seed_member = fn group, user ->
  # Una membresía por usuario (`group_members_user_id_unique_index`,
  # 20260917011526): la búsqueda es por `user_id` solo. Si el usuario ya
  # pertenece a OTRO grupo (p. ej. el admin real de producción), reusar esa
  # membresía — reinsertar violaría el índice y abortaría el boot del deploy.
  case Repo.get_by(Tokengate.Accounts.GroupMember, user_id: user.id) do
    nil ->
      {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
      member

    member ->
      member
  end
end

dev_member = seed_member.(dev_group, dev_user)
qa_member = seed_member.(qa_group, tester_user)
_admin_in_dev = seed_member.(dev_group, admin)

# ---------------------------------------------------------------------------
# Service (subject_type "service" for machine-to-machine usage)
# ---------------------------------------------------------------------------

service =
  case Repo.get_by(Tokengate.Accounts.Service, name: "ci-bot") do
    nil ->
      {:ok, service} =
        Accounts.create_service(%{
          name: "ci-bot",
          concurrency_limit: 10,
          rpm_limit: 120,
          monthly_spend_limit_usd: Decimal.new("50.00")
        })

      IO.puts("Seeded service: #{service.name}")
      service

    service ->
      service
  end

# ---------------------------------------------------------------------------
# Topups (credit for a user and for the service)
# ---------------------------------------------------------------------------

seed_topup = fn attrs ->
  case Repo.get_by(Tokengate.Credits.Topup, label: attrs[:label] || attrs["label"]) do
    nil ->
      {:ok, topup} = Topups.create(attrs)
      topup

    topup ->
      topup
  end
end

seed_topup.(%{
  user_id: dev_user.id,
  amount_usd: Decimal.new("10.00"),
  label: "seed-dev-topup",
  note: "Seed: crédito inicial para dev"
})

seed_topup.(%{
  service_id: service.id,
  amount_usd: Decimal.new("20.00"),
  label: "seed-service-topup",
  note: "Seed: crédito inicial para ci-bot"
})

# ---------------------------------------------------------------------------
# Models of every type (llm, embedding + the media services route as llm)
# ---------------------------------------------------------------------------

seed_model = fn name, attrs ->
  case Providers.get_model_by_name(name) do
    nil ->
      {:ok, model} = Providers.create_model(Map.merge(%{"name" => name}, attrs))
      IO.puts("Seeded model: #{model.name} (#{model.model_type})")
      model

    model ->
      model
  end
end

gpt = seed_model.("gpt-5-nano", %{"context_window" => 400_000, "model_type" => "llm"})
glm = seed_model.("glm-5.2", %{"context_window" => 1_000_000, "model_type" => "llm"})
embed = seed_model.("text-embedding", %{"context_window" => 8_192, "model_type" => "embedding"})
rerank = seed_model.("qwen3-rerank", %{"context_window" => 120_000, "model_type" => "llm"})
tts = seed_model.("qwen3-tts", %{"context_window" => 512, "model_type" => "llm"})
video = seed_model.("wan-t2v", %{"context_window" => 2_048, "model_type" => "llm"})

# ---------------------------------------------------------------------------
# Provider credentials — DUMMY keys, replace from the Providers page
# ---------------------------------------------------------------------------

seed_credential = fn provider_key, name ->
  provider = Repo.get_by(Tokengate.Providers.Provider, key: provider_key)

  if provider do
    case Repo.get_by(Tokengate.Providers.Credential, provider_id: provider.id, name: name) do
      nil ->
        {:ok, cred} =
          Providers.create_credential(%{
            provider_id: provider.id,
            name: name,
            api_key_encrypted: "sk-seed-#{provider_key}-replace-me",
            status: "active"
          })

        IO.puts("Seeded credential: #{name} (#{provider_key})")
        cred

      cred ->
        cred
    end
  else
    IO.puts("Provider #{provider_key} not materialized — skipped its credential")
    nil
  end
end

openrouter_cred = seed_credential.("openrouter", "seed-openrouter")
fireworks_cred = seed_credential.("fireworks-ai", "seed-fireworks")
alibaba_cred = seed_credential.("alibaba", "seed-alibaba")

# ---------------------------------------------------------------------------
# Model ↔ provider bindings (which upstream serves each alias)
# ---------------------------------------------------------------------------

seed_mp = fn model, provider_key, cred, provider_model, priority ->
  existing =
    Repo.get_by(Tokengate.Providers.ModelProvider,
      model_id: model.id,
      credential_id: cred && cred.id
    )

  case existing do
    nil ->
      {:ok, _mp} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: cred.id,
          provider_model: provider_model,
          priority: priority,
          enabled: true
        })

      IO.puts("Seeded binding: #{model.name} ← #{provider_key} (#{provider_model})")

    _mp ->
      :ok
  end
end

seed_mp.(gpt, "openrouter", openrouter_cred, "openai/gpt-5-nano", 1)
seed_mp.(glm, "openrouter", openrouter_cred, "z-ai/glm-5.2", 1)
seed_mp.(embed, "fireworks-ai", fireworks_cred, "fireworks/nomic-embed", 1)
seed_mp.(rerank, "alibaba", alibaba_cred, "qwen3-rerank", 1)
seed_mp.(rerank, "fireworks-ai", fireworks_cred, "accounts/fireworks/models/qwen3-reranker-8b", 2)
seed_mp.(tts, "alibaba", alibaba_cred, "qwen3-tts-flash", 1)
seed_mp.(video, "alibaba", alibaba_cred, "wan2.7-t2v", 1)

# ---------------------------------------------------------------------------
# Grants — who can route to what
# ---------------------------------------------------------------------------

seed_grant = fn group, model ->
  case Repo.get_by(Tokengate.Providers.GroupModel, group_id: group.id, model_id: model.id) do
    nil ->
      {:ok, _} = Providers.grant_model_to_group(group.id, model.id)
      IO.puts("Seeded grant: #{group.name} → #{model.name}")

    _ ->
      :ok
  end
end

seed_grant.(dev_group, gpt)
seed_grant.(dev_group, glm)
seed_grant.(dev_group, embed)
seed_grant.(dev_group, rerank)
seed_grant.(qa_group, embed)
seed_grant.(qa_group, tts)

# ---------------------------------------------------------------------------
# Proxy API keys — the tg- tokens clients send as Bearer
# ---------------------------------------------------------------------------

seed_api_key = fn label, attrs ->
  case Repo.get_by(Tokengate.Accounts.ApiKey, label: label) do
    nil ->
      {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      {:ok, _api_key} =
        Accounts.create_api_key(
          Map.merge(
            %{
              "key_hash" => key_hash,
              "key_prefix" => key_prefix,
              "status" => "active"
            },
            attrs
          )
        )

      IO.puts("Seeded API key: #{label} → #{token}")

    _api_key ->
      IO.puts("API key #{label} already exists (token shown only once, at creation)")
  end
end

# NOTE: the plaintext token is printed ONCE here. On re-run the key already
# exists and the token is NOT recoverable — revoke and re-create if lost.
seed_api_key.("seed-dev-key", %{
  "subject_type" => "member",
  "user_id" => dev_user.id,
  "group_member_id" => dev_member.id,
  "label" => "seed-dev-key"
})

seed_api_key.("seed-qa-key", %{
  "subject_type" => "member",
  "user_id" => tester_user.id,
  "group_member_id" => qa_member.id,
  "label" => "seed-qa-key"
})

IO.puts("""
Seeds complete.

  Login (admin):  #{admin_email} / #{admin_password}
  Login (dev):    dev@tokengate.local / #{demo_password}
  Login (tester): tester@tokengate.local / #{demo_password}

  Provider credentials are PLACEHOLDERS (sk-seed-...) — replace them from
  the Providers page before proxying real traffic.
""")
