defmodule TokengateWeb.StatsChartsTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}

  defp register(role) do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "chart-#{u}@example.com",
        name: "Chart #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn |> post(~p"/login", %{email: user.email, password: password}) |> recycle()
  end

  defp group_with_log(opts) do
    u = System.unique_integer([:positive])
    {:ok, group} = Accounts.create_group(%{name: "Chart Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "chart-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, ma} = Providers.create_model(%{name: "model-#{u}", context_window: 128_000})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: ma.id,
        model_requested: "model-#{u}",
        model_responded: "model-#{u}",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: Map.get(opts, :prompt_tokens, 100),
        completion_tokens: Map.get(opts, :completion_tokens, 50),
        provider_cost_usd: Map.fetch!(opts, :cost),
        latency_ms: 42,
        streaming: false,
        inserted_at: Map.fetch!(opts, :inserted_at)
      })

    :ok
  end

  # Fixture built once, then N logs inserted against it. `group_with_log/1`
  # re-registers a user each call (bcrypt), which is far too slow to call
  # hundreds of times for a busy-peak scenario.
  defp log_fixture do
    u = System.unique_integer([:positive])
    {:ok, group} = Accounts.create_group(%{name: "Bulk Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "bulk-owner-#{u}@example.com",
        name: "Bulk #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "BulkProv #{u}", base_url: "http://localhost:1"})

    {:ok, ma} = Providers.create_model(%{name: "bulk-#{u}", context_window: 128_000})

    fn inserted_at ->
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          provider_id: provider.id,
          model_id: ma.id,
          model_requested: "bulk-#{u}",
          model_responded: "bulk-#{u}",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.001"),
          latency_ms: 42,
          streaming: false,
          inserted_at: inserted_at
        })

      :ok
    end
  end

  # Bar heights as rendered in a chart card, in DOM order.
  defp bar_heights(view, id) do
    view
    |> element("##{id}")
    |> render()
    |> then(&Regex.scan(~r/height:\s*(\d+)%/, &1))
    |> Enum.map(fn [_, h] -> String.to_integer(h) end)
  end

  describe "gráficas por minuto" do
    test "dibujan una barra por minuto con altura proporcional al tráfico", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 4 requests en un minuto, 1 en otro → la barra del pico al 100%.
      for _ <- 1..4 do
        group_with_log(%{
          cost: Decimal.new("0.001"),
          inserted_at: DateTime.add(now, -10, :second)
        })
      end

      group_with_log(%{cost: Decimal.new("0.001"), inserted_at: DateTime.add(now, -70, :second)})

      {:ok, view, _html} = live(conn, ~p"/stats")

      for id <- ~w(live-minute-chart live-tokens-minute-chart live-cost-minute-chart) do
        heights = bar_heights(view, id)

        # Una barra por minuto de la ventana, y exactamente dos pobladas.
        assert length(heights) == 60
        assert Enum.sort(Enum.reject(heights, &(&1 == 0)), :desc) == [100, 25]
      end

      # Con datos, el pie de "sin tráfico" desaparece.
      refute has_element?(view, "#live-minute-chart span", "sin tráfico en la última hora")
    end

    test "un minuto con tráfico nunca se dibuja a 0% (barra invisible)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      insert = log_fixture()

      # Pico alto: 500 requests en un minuto. Un minuto con 1 request da
      # 0.2% crudo → redondeaba a 0% y la barra desaparecía, justo el caso
      # que el gráfico debería mostrar. Se insertan en lote: bcrypt por
      # request hacía el test inservible.
      for _ <- 1..500, do: insert.(DateTime.add(now, -10, :second))
      insert.(DateTime.add(now, -70, :second))

      {:ok, view, _html} = live(conn, ~p"/stats")

      heights = bar_heights(view, "live-minute-chart")
      populated = Enum.reject(heights, &(&1 == 0))

      # Pico al 100% y el minuto de 1 request con altura visible (no 0).
      assert 100 in populated
      assert length(populated) == 2
      assert Enum.min(populated) >= 2
    end

    test "la barra del minuto vacío sí queda en 0% (relleno de la ventana)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      group_with_log(%{cost: Decimal.new("0.001"), inserted_at: DateTime.add(now, -10, :second)})

      {:ok, view, _html} = live(conn, ~p"/stats")

      heights = bar_heights(view, "live-minute-chart")

      assert length(heights) == 60
      # 59 buckets vacíos intactos en 0; el poblado al 100.
      assert Enum.count(heights, &(&1 == 0)) == 59
      assert Enum.max(heights) == 100
    end

    test "la cabecera muestra promedio y pico, no solo el pico", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 4 requests en un minuto y 1 en otro: pico 4 req/min y media 5/60 = 0.1.
      # Los 58 minutos vacíos cuentan en el denominador, así que el promedio
      # describe la ventana completa y no sólo los minutos con tráfico.
      for _ <- 1..4 do
        group_with_log(%{
          cost: Decimal.new("0.001"),
          inserted_at: DateTime.add(now, -10, :second)
        })
      end

      group_with_log(%{cost: Decimal.new("0.001"), inserted_at: DateTime.add(now, -70, :second)})

      {:ok, view, _html} = live(conn, ~p"/stats")

      # 5 requests × (100 in + 50 out) = 750 tokens → 12.5/min, y $0.005 →
      # $0.000083/min (a cuatro decimales, como el pico, sería $0.0).
      assert has_element?(
               view,
               "#live-minute-chart-header-stats",
               "avg 0.1 req/min · peak 4 req/min"
             )

      assert has_element?(
               view,
               "#live-tokens-minute-chart-header-stats",
               "avg 13 tok/min · peak 600 tok/min"
             )

      assert has_element?(
               view,
               "#live-cost-minute-chart-header-stats",
               "avg $0.000083/min · peak $0.004/min"
             )
    end

    test "sin tráfico la cabecera no inventa un promedio de cero", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats")

      for id <- ~w(live-minute-chart live-tokens-minute-chart live-cost-minute-chart) do
        refute has_element?(view, "##{id}-header-stats")
      end
    end
  end
end
