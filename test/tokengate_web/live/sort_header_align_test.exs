defmodule TokengateWeb.SortHeaderAlignTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}

  @moduledoc """
  Regresión de alineación: los headers ordenables alineados a la derecha
  deben llenar su celda (`w-full`), igual que `AdminComponents.sort_button`.
  Sin `w-full` el botón flex encoge y el label queda a la izquierda mientras
  los valores de la columna están a la derecha.
  """

  defp unique, do: System.unique_integer([:positive])

  test "right-aligned sort headers fill their cell (w-full)", %{conn: conn} do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "align-#{u}@example.com",
        name: "Align #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    {:ok, group} = Accounts.create_group(%{name: "Align Group #{u}"})
    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, model} = Providers.create_model(%{name: "model-#{u}", context_window: 128_000})
    {:ok, service} = Accounts.create_service(%{name: "Align Service #{u}"})

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: model.id,
        model_requested: "model-#{u}",
        model_responded: "model-#{u}",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.005",
        latency_ms: 42,
        streaming: false
      })

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        service_id: service.id,
        provider_id: provider.id,
        model_id: model.id,
        model_requested: "model-#{u}",
        model_responded: "model-#{u}",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 80,
        completion_tokens: 40,
        provider_cost_usd: "0.003",
        latency_ms: 30,
        streaming: false
      })

    conn =
      conn
      |> post(~p"/login", %{email: user.email, password: "password-secret-#{u}1"})
      |> recycle()

    numeric_fields = ~w(request_count cost_usd prompt_tokens completion_tokens avg_tps)

    for path <- ["/stats/models", "/stats/groups", "/stats/users", "/stats/services"] do
      {:ok, view, _html} = live(conn, path)

      # Stats load async (assign_async) — sync with the LiveView until done.
      wait_stats_loaded(view)

      for field <- numeric_fields do
        assert has_element?(view, "th button[phx-value-field='#{field}'].w-full"),
               "#{path}: sort button #{field} lacks w-full (right-aligned header shrinks)"
      end
    end
  end

  defp wait_stats_loaded(view, attempts \\ 200)

  defp wait_stats_loaded(view, attempts) when attempts > 0 do
    state = :sys.get_state(view.pid)

    case get_in(state, [Access.key(:socket), Access.key(:assigns), Access.key(:stats_loading)]) do
      false ->
        :ok

      _other ->
        Process.sleep(10)
        wait_stats_loaded(view, attempts - 1)
    end
  end

  defp wait_stats_loaded(_view, 0), do: raise("stats async data never loaded")
end
