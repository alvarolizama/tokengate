defmodule Tokengate.Providers.CatalogRefreshWorkerTest do
  @moduledoc """
  The models.dev refresh, against a live Bandit server: what it writes, what it
  refuses to write, and the two properties the operator depends on — an
  upstream base-URL move is applied but surfaced, and a failed fetch degrades
  nothing. The lab half runs through the same worker: a second Bandit serves
  the models payload the labs are derived from.
  """

  use Tokengate.DataCase, async: false

  import Ecto.Query

  alias Tokengate.Providers

  alias Tokengate.Providers.{
    CatalogProvider,
    CatalogRefreshWorker,
    Lab,
    Provider
  }

  @port 42391

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # One server per test, routes keyed by path: `/api.json` (providers) and
    # `/models.json` (the list labs are derived from) can serve different
    # payloads, and a test can swap a route's payload mid-test without
    # rebinding the port.
    def call(conn, _opts) do
      routes = :persistent_term.get({__MODULE__, :routes}, %{})
      {body, status} = Map.get(routes, conn.request_path, {"{}", 200})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end

  setup do
    previous = Application.get_env(:tokengate, :catalog_refresh_url)

    on_exit(fn ->
      if previous do
        Application.put_env(:tokengate, :catalog_refresh_url, previous)
      else
        Application.delete_env(:tokengate, :catalog_refresh_url)
      end

      Application.delete_env(:tokengate, :labs_refresh_url)
    end)

    # The boot sync runs outside the test sandbox (and can be cut short), so
    # make the mirror + materialization deterministic for this test process.
    Tokengate.Providers.CatalogSeed.seed_if_empty()
    Tokengate.Providers.CatalogSeed.seed_labs_if_empty()
    :ok = Tokengate.Providers.CatalogSync.sync()

    # Leftover refresh jobs from a manual run in the shared test database would
    # make the busy-state assertions meaningless (Oban is in manual mode here,
    # so a queued job never drains).
    Repo.delete_all(from j in Oban.Job, where: j.worker == ^inspect(CatalogRefreshWorker))

    :ok
  end

  # One Bandit on @port serves BOTH endpoints, distinguished by path. A single
  # origin also matches production: `labs_url/0` derives `/models.json` from
  # the provider URL's origin, so pointing the refresh at the test server moves
  # both halves together.
  defp serve!(routes, status \\ 200) when is_map(routes) do
    default = Enum.map(routes, fn {path, payload} -> {path, {Jason.encode!(payload), status}} end)
    :persistent_term.put({TestPlug, :routes}, Map.new(default))
    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})
    Application.put_env(:tokengate, :catalog_refresh_url, "http://127.0.0.1:#{@port}/api.json")
    Application.delete_env(:tokengate, :labs_refresh_url)
    :ok
  end

  defp re_route!(path, payload) do
    routes =
      :persistent_term.get({TestPlug, :routes}, %{})
      |> Map.put(path, {Jason.encode!(payload), 200})

    :persistent_term.put({TestPlug, :routes}, routes)
  end

  defp mirror(key), do: Repo.get(CatalogProvider, key)
  defp provider(key), do: Repo.get_by(Provider, key: key)
  defp lab(key), do: Repo.get(Lab, key)

  defp credential_for!(key) do
    p = Repo.get_by!(Provider, key: key)

    {:ok, cred} =
      Providers.create_credential(%{
        provider_id: p.id,
        name: "Producción",
        api_key_encrypted: "«redacted:sk-…»",
        status: "active"
      })

    cred
  end

  defp perform do
    CatalogRefreshWorker.perform(%Oban.Job{})
  end

  describe "happy path" do
    test "upserts new providers and materializes them without a restart" do
      serve!(%{
        "/api.json" => %{
          "alpha" => %{
            "id" => "alpha",
            "name" => "Alpha Cloud",
            "api" => "https://api.alpha.example/v1/",
            "doc" => "https://docs.alpha.example",
            "env" => ["ALPHA_API_KEY"],
            "npm" => "@ai-sdk/openai-compatible"
          }
        }
      })

      assert :ok = perform()

      # Mirror row (trailing slash trimmed).
      row = mirror("alpha")
      assert row.name == "Alpha Cloud"
      assert row.base_url == "https://api.alpha.example/v1"
      assert row.logo_url == "https://models.dev/logos/alpha.svg"
      assert row.status == "active"

      # Materialized immediately, so the provider shows up in the modal and in
      # the list without waiting for a boot.
      p = provider("alpha")
      assert p
      assert p.source == "builtin"
      assert p.base_url == "https://api.alpha.example/v1"
      assert p.doc_url == "https://docs.alpha.example"

      state = Providers.catalog_sync_state()
      assert state.source == "models.dev"
      assert state.inserted >= 1
      assert state.error == nil
    end

    test "an unchanged upstream payload is not rewritten" do
      serve!(%{
        "/api.json" => %{
          "beta" => %{
            "id" => "beta",
            "name" => "Beta",
            "api" => "https://api.beta.example/v1",
            "doc" => "https://docs.beta.example",
            "env" => ["BETA_API_KEY"],
            "npm" => "@ai-sdk/openai-compatible"
          }
        }
      })

      assert :ok = perform()
      first = mirror("beta")

      assert :ok = perform()
      second = mirror("beta")

      assert second.fingerprint == first.fingerprint
      assert Providers.catalog_sync_state().unchanged >= 1
    end

    test "a provider that disappeared upstream is marked stale, never deleted" do
      # The mirror is seeded from the snapshot, so "gamma" is not in it: use an
      # existing row as the one that goes missing upstream.
      assert mirror("deepseek")
      assert provider("deepseek")

      serve!(%{
        "/api.json" => %{
          "alpha" => %{
            "id" => "alpha",
            "name" => "Alpha",
            "api" => "https://api.alpha.example/v1",
            "doc" => "https://docs.alpha.example",
            "npm" => "@ai-sdk/openai-compatible"
          }
        }
      })

      assert :ok = perform()

      assert mirror("deepseek").status == "stale"
      assert Providers.catalog_sync_state().stale >= 1
      # Its materialized row survives: it may be serving traffic.
      assert provider("deepseek")
    end

    test "a code-owned provider models.dev never publishes is NOT swept stale" do
      # El refresh solo es dueño de las filas que models.dev publica. Surplus no
      # está en su payload —ni estará nunca—, así que un barrido ingenuo lo
      # dejaría `stale`; y como `materialize/1` salta las filas stale, quedaría
      # congelado con un warning `already_stale` en cada corrida semanal.
      assert :ok = Tokengate.Providers.CatalogSync.ensure_code_providers()
      assert mirror("surplus-intelligence").status == "active"

      serve!(%{
        "/api.json" => %{
          "alpha" => %{
            "id" => "alpha",
            "name" => "Alpha",
            "api" => "https://api.alpha.example/v1",
            "doc" => "https://docs.alpha.example",
            "npm" => "@ai-sdk/openai-compatible"
          }
        }
      })

      assert :ok = perform()

      row = mirror("surplus-intelligence")
      assert row.status == "active"
      assert row.base_url == "https://api.surplusintelligence.ai/v1"

      # Y sigue materializado sin reiniciar: el refresh lo vuelve a materializar
      # en la misma corrida.
      assert provider("surplus-intelligence")

      # Ningún warning lo nombra: no se reporta como algo que "desapareció".
      state = Providers.catalog_sync_state()
      refute Enum.any?(state.warnings || [], &(&1["key"] == "surplus-intelligence"))
    end
  end

  describe "base URL drift" do
    test "applies the new base URL and warns when the provider has credentials" do
      credential_for!("fireworks-ai")
      assert provider("fireworks-ai").base_url == "https://api.fireworks.ai/inference/v1"

      serve!(%{
        "/api.json" => %{
          "fireworks-ai" => %{
            "id" => "fireworks-ai",
            "name" => "Fireworks AI",
            "api" => "https://api.fireworks.ai/inference/v2",
            "doc" => "https://fireworks.ai/docs/",
            "env" => ["FIREWORKS_API_KEY"],
            "npm" => "@ai-sdk/openai-compatible"
          }
        },
        "/models.json" => %{}
      })

      assert :ok = perform()

      # Applied: mirror and materialized row both follow upstream.
      assert mirror("fireworks-ai").base_url == "https://api.fireworks.ai/inference/v2"
      assert provider("fireworks-ai").base_url == "https://api.fireworks.ai/inference/v2"

      # Surfaced, because live traffic silently changed destination.
      warnings = Providers.catalog_sync_state().warnings

      assert [warning] = Enum.filter(warnings, &(&1["reason"] == "base_url_changed"))
      assert warning["key"] == "fireworks-ai"
      assert warning["from"] == "https://api.fireworks.ai/inference/v1"
      assert warning["to"] == "https://api.fireworks.ai/inference/v2"
      assert warning["credentials"] == 1
    end

    test "no warning when the provider has no credentials yet" do
      Repo.delete_all(from(c in Tokengate.Providers.Credential))

      serve!(%{
        "/api.json" => %{
          "fireworks-ai" => %{
            "id" => "fireworks-ai",
            "name" => "Fireworks AI",
            "api" => "https://api.fireworks.ai/inference/v2",
            "doc" => "https://fireworks.ai/docs/",
            "npm" => "@ai-sdk/openai-compatible"
          }
        },
        "/models.json" => %{}
      })

      assert :ok = perform()

      # The providers half emits no drift warning; the lab and model halves
      # cannot derive anything from `{}` (this payload has no model list), which
      # is recorded as a warning each, not a provider one.
      no_provider_warnings =
        Providers.catalog_sync_state().warnings
        |> Enum.reject(&(&1["reason"] in ["labs_payload_empty", "models_payload_empty"]))

      assert no_provider_warnings == []
    end
  end

  describe "failure" do
    test "a fetch error records itself and marks NOTHING stale" do
      Application.put_env(
        :tokengate,
        :catalog_refresh_url,
        "http://127.0.0.1:#{@port}/api.json"
      )

      # No server was started on @port for this test.
      assert {:error, reason} = perform()
      assert reason =~ "could not download"

      state = Providers.catalog_sync_state()
      assert state.error =~ "could not download"
      assert state.stale == 0

      # The catalog is intact: nothing flipped to stale on a network failure.
      assert Repo.aggregate(
               from(c in CatalogProvider, where: c.status == "stale"),
               :count
             ) == 0
    end

    test "a non-200 answer is an error, not an empty catalog" do
      serve!(%{"/api.json" => %{}}, 503)

      assert {:error, reason} = perform()
      assert reason =~ "503"

      # Nada se perdió: el mirror sigue con el snapshot + los code-owned (que no
      # vienen de models.dev y por eso no los toca un fetch fallido).
      assert Repo.aggregate(CatalogProvider, :count) ==
               Providers.Catalog.snapshot_size() + length(Providers.Catalog.code_provider_keys())
    end
  end

  describe "enqueueing" do
    test "in_flight?/0 tracks the queued job" do
      refute CatalogRefreshWorker.in_flight?()

      assert {:ok, _job} = Providers.request_catalog_refresh()
      assert CatalogRefreshWorker.in_flight?()
    end
  end

  # ---------------------------------------------------------------------------
  # Labs — the same Bandit serves `/models.json`; `labs_url/0` derives it from
  # the provider URL's origin, which these tests leave pointing at the test
  # server (they never set `:labs_refresh_url`).
  # ---------------------------------------------------------------------------

  defp lab_providers_payload do
    # One provider entry the gateway can materialize, so the lab's name lookup
    # has a real source.
    %{
      "openai" => %{
        "id" => "openai",
        "name" => "OpenAI",
        "api" => "https://api.openai.example/v1",
        "doc" => "https://platform.openai.example/docs",
        "env" => ["OPENAI_API_KEY"],
        "npm" => "@ai-sdk/openai-compatible"
      }
    }
  end

  defp lab_models_payload do
    %{
      "openai/gpt-5" => %{
        "id" => "openai/gpt-5",
        "release_date" => "2026-01-10",
        "last_updated" => "2026-03-01"
      },
      "openai/gpt-5-mini" => %{
        "id" => "openai/gpt-5-mini",
        "release_date" => "2026-02-20",
        "last_updated" => "2026-03-01"
      },
      "anthropic/claude-opus-4.7" => %{
        "id" => "anthropic/claude-opus-4.7",
        "release_date" => "2026-01-05",
        "last_updated" => "2026-02-11"
      },
      # No lab prefix: cannot be attributed to any lab.
      "gpt-5-orphan" => %{"id" => "gpt-5-orphan", "release_date" => "2026-01-01"}
    }
  end

  describe "labs" do
    test "derives and upserts labs from the canonical model list" do
      serve!(%{"/api.json" => lab_providers_payload(), "/models.json" => lab_models_payload()})

      assert :ok = perform()

      state = Providers.catalog_sync_state()
      # The mirror is pre-seeded with 37 builtin labs; the models payload only
      # mentions two, so the rest sweep to stale. Nothing new to insert here.
      assert state.labs_updated == 2

      assert state.labs_stale ==
               Providers.LabCatalog.snapshot_size() - 2

      assert state.error == nil

      openai = lab("openai")
      assert openai.name == "OpenAI"
      assert openai.logo_url == "https://models.dev/logos/labs/openai.svg"
      assert openai.model_count == 2
      # Verbatim upstream dates, newest first.
      assert openai.last_released == "2026-02-20"
      assert openai.last_updated == "2026-03-01"
      assert openai.status == "active"
      assert openai.source == "builtin"

      anthropic = lab("anthropic")
      assert anthropic.model_count == 1
      assert anthropic.last_released == "2026-01-05"
    end

    test "an unchanged payload is not rewritten and a missing lab goes stale" do
      serve!(%{"/api.json" => lab_providers_payload(), "/models.json" => lab_models_payload()})
      assert :ok = perform()

      first = lab("openai")

      # anthropic vanishes upstream; openai keeps its values.
      re_route!("/models.json", %{
        "openai/gpt-5" => lab_models_payload()["openai/gpt-5"],
        "openai/gpt-5-mini" => lab_models_payload()["openai/gpt-5-mini"]
      })

      assert :ok = perform()

      assert lab("openai").fingerprint == first.fingerprint
      assert lab("anthropic").status == "stale"

      state = Providers.catalog_sync_state()
      assert state.labs_stale == 1
      assert state.labs_updated == 0
    end

    test "a custom lab is never touched by the refresh" do
      serve!(%{"/api.json" => lab_providers_payload(), "/models.json" => lab_models_payload()})

      {:ok, _custom} =
        Providers.create_custom_lab(%{
          "name" => "Mi Lab",
          "key" => "mi-lab",
          "icon" => "hero-beaker"
        })

      assert :ok = perform()

      fresh = lab("mi-lab")
      assert fresh.source == "custom"
      assert fresh.icon == "hero-beaker"
      assert fresh.logo_url == nil
      assert fresh.fetched_at == nil
      # The custom row is invisible to the stale sweep too.
      assert fresh.status == "active"
    end

    test "a labs fetch failure is a warning and changes nothing" do
      # Providers endpoint answers; the models endpoint answers 503.
      serve!(%{"/api.json" => lab_providers_payload()}, 200)
      # `:labs_refresh_url` overrides the derived URL, so point it at a port
      # with no server at all.
      Application.put_env(:tokengate, :labs_refresh_url, "http://127.0.0.1:9/models.json")

      assert :ok = perform()

      state = Providers.catalog_sync_state()
      assert state.error == nil

      assert [warning] = Enum.filter(state.warnings, &(&1["reason"] == "labs_fetch_failed"))
      assert warning["message"] =~ "could not download"

      # No lab was marked stale by the network failure.
      assert Repo.aggregate(from(l in Lab, where: l.status == "stale"), :count) == 0
    end

    test "an empty models payload is refused, not swept to stale" do
      serve!(%{"/api.json" => lab_providers_payload(), "/models.json" => %{}})

      assert :ok = perform()

      state = Providers.catalog_sync_state()

      assert [_warning] = Enum.filter(state.warnings, &(&1["reason"] == "labs_payload_empty"))

      # Every seeded lab is still active.
      assert Repo.aggregate(from(l in Lab, where: l.status == "active"), :count) ==
               Providers.LabCatalog.snapshot_size()
    end
  end
end
