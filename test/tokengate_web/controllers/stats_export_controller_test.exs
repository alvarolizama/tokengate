defmodule TokengateWeb.StatsExportControllerTest do
  @moduledoc """
  CSV export endpoint tests — focusing on authorization: the group drill-down
  exposes member-level data (emails, costs), so only admins may export it.
  """

  use TokengateWeb.ConnCase, async: false
  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "export-#{u}@example.com",
        name: "Export #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  # Group with one member (owner) and one request log.
  defp group_with_log(opts \\ []) do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "P #{u}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: nil,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        agent_type: "claude-code",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.005",
        latency_ms: 42,
        streaming: false,
        inserted_at:
          Keyword.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{
      group: group,
      owner: owner,
      member: member,
      provider: provider,
      owner_password: "password-secret-#{u}1"
    }
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    conn = get(conn, ~p"/stats/export?type=groups")
    assert redirected_to(conn) =~ "/login"
  end

  test "admin can export a group drill-down", %{conn: conn} do
    %{group: group} = group_with_log()
    %{user: admin, password: password} = register("admin")

    conn =
      conn
      |> login(admin, password)
      |> get(~p"/stats/export?type=groups&group_id=#{group.id}")

    assert response(conn, 200) =~ "usuario,perfil"
  end

  test "plain member of the group cannot export its drill-down", %{conn: conn} do
    %{group: group, owner: owner, owner_password: password} = group_with_log()

    conn =
      conn
      |> login(owner, password)
      |> get(~p"/stats/export?type=groups&group_id=#{group.id}")

    assert json_response(conn, 403) == %{"error" => "no autorizado"}
  end

  test "non-member user gets 403 on another group's drill-down", %{conn: conn} do
    %{group: group} = group_with_log()
    %{user: outsider, password: password} = register("user")

    conn =
      conn
      |> login(outsider, password)
      |> get(~p"/stats/export?type=groups&group_id=#{group.id}")

    assert json_response(conn, 403) == %{"error" => "no autorizado"}
  end

  test "models export works for any authenticated user", %{conn: conn} do
    group_with_log()
    %{user: user, password: password} = register("user")

    conn =
      conn
      |> login(user, password)
      |> get(~p"/stats/export?type=models")

    assert response(conn, 200) =~ "modelo,requests"
  end

  test "providers export: el desglose de la tabla, y sólo para admins", %{conn: conn} do
    %{provider: provider} = group_with_log()
    %{user: admin, password: admin_password} = register("admin")

    conn =
      conn
      |> login(admin, admin_password)
      |> get(~p"/stats/export?type=providers&period=today")

    body = response(conn, 200)

    assert body =~ "proveedor,tier,score,requests,fallos,latencia_ms,p95_ms,ttft_ms"
    assert body =~ provider.name

    # La fila trae el mismo desglose que la tabla: con 1 request no hay tier ni
    # score (< 10 requests), los fallos van como porcentaje y las latencias en ms.
    row = body |> String.split("\n") |> Enum.find(&String.contains?(&1, provider.name))
    assert row == "#{provider.name},—,,1,0.0,42,42,"

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "estadisticas_proveedores_"
    assert disposition =~ ".csv"

    # Un no-admin no baja el ranking completo: la pestaña es admin-only y
    # `provider_ranking/2` no sabe filtrar por scope de miembro.
    %{user: plain, password: plain_password} = register("user")

    forbidden_conn =
      build_conn()
      |> login(plain, plain_password)
      |> get(~p"/stats/export?type=providers&period=today")

    assert response(forbidden_conn, 403) =~ "no autorizado"
  end

  test "providers export: respeta la ventana cerrada de ayer", %{conn: conn} do
    # Midday of the closed UTC day before today: inside `yesterday`, outside
    # `today`. Both windows are UTC-anchored, so this holds on every weekday —
    # a "week"-based fixture would flake on Mondays.
    yesterday_mid =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.add(-1)
      |> DateTime.new!(~T[12:00:00], "Etc/UTC")

    %{provider: old_provider} = group_with_log(inserted_at: yesterday_mid)

    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)

    # El log de ayer queda FUERA de "today" y DENTRO de "ayer": el export tiene
    # que respetar el borde superior de la ventana cerrada (antes, un lector que
    # sólo usaba `from` lo contaba en las dos).
    refute get(conn, ~p"/stats/export?type=providers&period=today").resp_body =~
             old_provider.name

    assert get(conn, ~p"/stats/export?type=providers&period=yesterday").resp_body =~
             old_provider.name
  end

  # Un servicio (subject_type "service") con un log propio.
  defp service_with_log(opts \\ []) do
    u = unique()

    {:ok, service} = Accounts.create_service(%{name: "Svc #{u}"})

    {:ok, provider} =
      Providers.create_provider(%{name: "PS #{u}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.005",
        latency_ms: 42,
        inserted_at:
          Keyword.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{service: service}
  end

  test "services export: una fila por servicio, y sólo para admins", %{conn: conn} do
    %{service: service} = service_with_log()
    %{user: admin, password: admin_password} = register("admin")

    conn =
      conn
      |> login(admin, admin_password)
      |> get(~p"/stats/export?type=services&period=today")

    body = response(conn, 200)

    assert body =~ "servicio,requests,costo,tokens_in,tokens_out,tps,latencia_ms"

    row = body |> String.split("\n") |> Enum.find(&String.contains?(&1, service.name))
    [_, requests, cost, tin, tout, tps, latency] = String.split(row, ",")

    assert requests == "1"
    assert cost == "0.005000"
    assert tin == "100"
    assert tout == "50"
    # 50 tokens / 42 ms
    assert tps == "1190.5"
    assert latency == "42"

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "estadisticas_servicios_"
    assert disposition =~ ".csv"

    # La pestaña Servicios es admin-only y `breakdown_by_service/1` no sabe
    # filtrar por scope de miembro: un no-admin no baja el ranking completo.
    %{user: plain, password: plain_password} = register("user")

    forbidden_conn =
      build_conn()
      |> login(plain, plain_password)
      |> get(~p"/stats/export?type=services&period=today")

    assert response(forbidden_conn, 403) =~ "no autorizado"
  end

  test "services export: celda de latencia vacía cuando no hay muestras", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    u = unique()
    {:ok, service} = Accounts.create_service(%{name: "NoLat #{u}"})

    {:ok, provider} =
      Providers.create_provider(%{name: "PN #{u}", base_url: "http://localhost:1"})

    # Un log de servicio sin latencia registrada: 0 sería un dato falso.
    {:ok, _} =
      Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        status_code: 200,
        prompt_tokens: 10,
        completion_tokens: 5,
        provider_cost_usd: "0.001",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn =
      conn
      |> login(admin, password)
      |> get(~p"/stats/export?type=services&period=today")

    row =
      response(conn, 200) |> String.split("\n") |> Enum.find(&String.contains?(&1, service.name))

    refute row == nil
    assert String.ends_with?(row, ",")
  end

  test "users export: una fila por usuario, y sólo para admins", %{conn: conn} do
    %{owner: owner, group: group} = group_with_log()
    %{user: admin, password: admin_password} = register("admin")

    conn =
      conn
      |> login(admin, admin_password)
      |> get(~p"/stats/export?type=users&period=today")

    body = response(conn, 200)

    assert body =~ "usuario,nombre,perfiles,requests,costo,tokens_in,tokens_out,tps"
    assert body =~ owner.email
    assert body =~ group.name

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "estadisticas_usuarios_"
    assert disposition =~ ".csv"

    %{user: plain, password: plain_password} = register("user")

    forbidden_conn =
      build_conn()
      |> login(plain, plain_password)
      |> get(~p"/stats/export?type=users&period=today")

    assert response(forbidden_conn, 403) =~ "no autorizado"
  end

  test "agents export: una fila por agente normalizado", %{conn: conn} do
    group_with_log()
    %{user: admin, password: admin_password} = register("admin")

    conn =
      conn
      |> login(admin, admin_password)
      |> get(~p"/stats/export?type=agents&period=today")

    body = response(conn, 200)

    assert body =~
             "agente,familia,requests,costo,share_pct,tokens_in,tokens_out,latencia_ms,errores,error_pct"

    assert body =~ "Claude Code"

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "estadisticas_agentes_"
    assert disposition =~ ".csv"
  end

  test "logs export neutralizes CSV formula injection in client_agent", %{conn: conn} do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})
    %{user: user, password: password} = register("user")

    {:ok, member} =
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "P #{u}", base_url: "http://localhost:1"})

    # Attacker-controlled value (arrives via the X-Title request header on
    # real proxy traffic) that Excel would execute as a formula.
    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: nil,
        model_requested: "gpt-4o",
        agent_type: "curl",
        client_agent: "=cmd|'/c calc'!A1",
        status_code: 200,
        prompt_tokens: 1,
        completion_tokens: 1,
        provider_cost_usd: "0",
        latency_ms: 1,
        streaming: false
      })

    conn =
      conn
      |> login(user, password)
      |> get(~p"/stats/export?type=logs")

    body = response(conn, 200)
    # Prefixed with a single quote — renders as text, never as a formula.
    assert body =~ "'=cmd|'/c calc'!A1"
  end

  test "logs export: la columna api_key muestra el label de la key viva", %{conn: conn} do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})
    %{user: user, password: password} = register("user")

    {:ok, member} =
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "P #{u}", base_url: "http://localhost:1"})

    {:ok, key} =
      Accounts.create_api_key(%{
        subject_type: "member",
        user_id: user.id,
        group_member_id: member.id,
        label: "Key Larga #{u}",
        key_hash: "hash-#{u}",
        key_prefix: "tg_live_#{u}"
      })

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        agent_type: "api",
        api_key_id: key.id,
        api_key_prefix: "tg_live_#{u}",
        status_code: 200,
        prompt_tokens: 1,
        completion_tokens: 1,
        provider_cost_usd: "0",
        latency_ms: 1,
        streaming: false,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Un log histórico sin api_key_id: la celda cae al prefijo de siempre.
    {:ok, _old_log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        agent_type: "api",
        api_key_prefix: "tg_old_#{u}",
        status_code: 200,
        prompt_tokens: 1,
        completion_tokens: 1,
        provider_cost_usd: "0",
        latency_ms: 1,
        streaming: false,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn =
      conn
      |> login(user, password)
      |> get(~p"/stats/export?type=logs&period=today")

    body = response(conn, 200)
    rows = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))

    key_row = Enum.find(rows, &String.contains?(&1, "Key Larga #{u}"))
    refute key_row == nil
    # El label de la key viva, no su prefijo.
    refute key_row =~ "tg_live_#{u}"

    old_row = Enum.find(rows, &String.contains?(&1, "tg_old_#{u}"))
    refute old_row == nil
  end

  test "logs export: la columna effort_applied distingue intención de valor aplicado", %{
    conn: conn
  } do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})
    %{user: user, password: password} = register("user")

    {:ok, member} =
      Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 1,
        completion_tokens: 1,
        provider_cost_usd: "0",
        latency_ms: 1,
        streaming: false,
        think: true,
        effort: "none",
        effort_applied: "low",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn =
      conn
      |> login(user, password)
      |> get(~p"/stats/export?type=logs")

    body = response(conn, 200)
    [header | rows] = body |> String.split("\n") |> Enum.reject(&(&1 == ""))

    # La columna nueva va junto a `effort`, en el mismo lugar que en la fila.
    assert header =~ "effort,effort_applied,tokens_in"

    row = Enum.find(rows, &String.contains?(&1, "Group #{u}"))
    refute row == nil
    assert row =~ "none,low,"
  end

  describe "logs export period coverage" do
    # F40: the export used to build the whole CSV in memory (up to 50k rows plus
    # preloads) and silently drop the tail past the cap. It now streams: the
    # response is chunked and fed by a `Repo.stream/2` cursor.
    test "streams the file in chunks and keeps every row of the window", %{conn: conn} do
      %{owner: owner, owner_password: password} = group_with_log()

      conn =
        conn
        |> login(owner, password)
        |> get(~p"/stats/export?type=logs&period=today")

      # `:chunked` is what `send_chunked/2` leaves on the conn: the body was
      # produced chunk by chunk, never as one buffered string.
      assert conn.state == :chunked

      body = response(conn, 200)
      [header | rows] = body |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert header =~ "fecha,estado"
      assert length(rows) == 1
      refute body =~ "TRUNCADO"
    end

    # The UI list is capped at 500 rows; exports must NOT be, otherwise a
    # busy day alone would eat the whole CSV and 30d exports would only
    # contain today's data.
    test "30d export includes logs older than the 500-row UI cap", %{conn: conn} do
      u = unique()
      {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})
      %{user: user, password: password} = register("user")

      {:ok, member} =
        Accounts.create_group_member(%{user_id: user.id, group_id: group.id})

      # 510 rows from 10 days ago — more than the old list_logs/1 cap of 500,
      # so the buggy export (ordered newest-first, capped at 500) would never
      # reach them when today has traffic.
      ten_days_ago =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      old_rows =
        for i <- 1..510 do
          %{
            id: Ecto.UUID.generate(),
            inserted_at: DateTime.add(ten_days_ago, i, :second),
            group_member_id: member.id,
            model_requested: "gpt-4o",
            agent_type: "api",
            status_code: 200,
            prompt_tokens: 10,
            completion_tokens: 5,
            latency_ms: 20,
            streaming: false,
            think: false
          }
        end

      {510, _} = Tokengate.Repo.insert_all(Tokengate.Logs.RequestLog, old_rows)

      # One row from today — newest-first ordering puts it at the top of the
      # buggy 500-row window.
      {:ok, _log} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4o",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 10,
          completion_tokens: 5,
          latency_ms: 20,
          streaming: false
        })

      conn =
        conn
        |> login(user, password)
        |> get(~p"/stats/export?type=logs&period=30d")

      body = response(conn, 200)
      data_rows = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
      assert length(data_rows) == 511
    end

    test "logs export: default canónico (week), 30d disponible y bookmarks huérfanos al default",
         %{conn: conn} do
      %{owner: owner, owner_password: password, member: member} = group_with_log()

      # Hace 10 días: dentro de 30d, fuera de la semana (que mide 7 días como
      # máximo, de lunes a ahora) — determinista cualquier día de la semana.
      ten_days_ago =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      {:ok, _old} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "old-model",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 1,
          completion_tokens: 1,
          latency_ms: 5,
          streaming: false,
          inserted_at: ten_days_ago
        })

      conn = login(conn, owner, password)

      default_body = response(get(conn, ~p"/stats/export?type=logs"), 200)

      assert default_body =~ "fecha,estado"
      # El log de hoy entra; el de hace 10 días no: el default es la semana.
      assert default_body =~ "gpt-4o"
      refute default_body =~ "old-model"

      # 30d sigue en el set canónico y sí lo trae.
      assert response(get(conn, ~p"/stats/export?type=logs&period=30d"), 200) =~ "old-model"

      # Bookmarks fuera del set (`month`, `last_month`, `7d`) y basura caen al
      # default sin reventar: exactamente el mismo CSV que sin periodo.
      for orphan <- ~w(month last_month 7d basura) do
        orphan_body = response(get(conn, "/stats/export?type=logs&period=#{orphan}"), 200)

        assert orphan_body == default_body
      end
    end

    test "errors export only includes status >= 400 across the period", %{conn: conn} do
      %{owner: owner, owner_password: password, member: member} = group_with_log()

      for status <- [400, 429, 500, 502] do
        {:ok, _} =
          Logs.log_request(%{
            group_member_id: member.id,
            model_requested: "gpt-4o",
            agent_type: "api",
            status_code: status,
            error_reason: "test_error",
            prompt_tokens: 1,
            completion_tokens: 1,
            latency_ms: 5,
            streaming: false
          })
      end

      conn =
        conn
        |> login(owner, password)
        |> get(~p"/stats/export?type=errors&period=30d")

      body = response(conn, 200)
      assert body =~ "test_error"

      # 200-row from group_with_log() must NOT appear in the errors export
      lines = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
      assert length(lines) == 4
    end

    test "logs export applies optional monitoring filters", %{conn: conn} do
      %{owner: owner, owner_password: password, member: member} = group_with_log()

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "filtered-match-model",
          agent_type: "opencode",
          status_code: 200,
          prompt_tokens: 1,
          completion_tokens: 1,
          latency_ms: 5,
          streaming: false
        })

      body =
        conn
        |> login(owner, password)
        |> get(~p"/stats/export?type=logs&period=30d&agent_type=opencode")
        |> response(200)

      assert body =~ "filtered-match-model"
      refute body =~ "gpt-4o"
    end
  end

  ## Type contract ----------------------------------------------------------

  describe "type contract" do
    test "an unknown type is a 400, never a silent models CSV", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      conn =
        conn
        |> login(admin, password)
        |> get(~p"/stats/export?type=facturas")

      # Antes caía al CSV de modelos: un archivo que decía `models` en el
      # nombre y en las columnas era una respuesta EQUIVOCADA, no un default.
      assert json_response(conn, 400) == %{"error" => "tipo de exportación desconocido"}
    end

    test "an omitted type keeps the models default", %{conn: conn} do
      %{owner: owner, owner_password: password} = group_with_log()

      body =
        conn
        |> login(owner, password)
        |> get(~p"/stats/export")
        |> response(200)

      assert body =~ "modelo,requests"
    end

    test "groups without group_id: the full table is admin-only" do
      group_with_log()
      %{user: plain, password: plain_password} = register("user")

      # Sin `group_id` el export es `Rollup.breakdown_by_group/1`, org-wide:
      # un no-admin no baja el listado completo (mismo criterio que el hub).
      forbidden =
        build_conn()
        |> login(plain, plain_password)
        |> get(~p"/stats/export?type=groups&period=today")

      assert json_response(forbidden, 403) == %{"error" => "no autorizado"}

      %{user: admin, password: admin_password} = register("admin")

      body =
        build_conn()
        |> login(admin, admin_password)
        |> get(~p"/stats/export?type=groups&period=today")
        |> response(200)

      assert body =~ "perfil,requests,costo"
    end
  end

  ## FinOps export ----------------------------------------------------------

  describe "finops export" do
    test "admin: one row per subject with unit economics", %{conn: conn} do
      u = unique()
      {:ok, group} = Accounts.create_group(%{name: "Fin Group #{u}"})

      {:ok, owner} =
        Accounts.register_user(%{
          email: "fin-owner-#{u}@example.com",
          name: "Fin Owner #{u}",
          password: "password-secret-#{u}1"
        })

      {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

      {:ok, provider} =
        Providers.create_provider(%{name: "Fin Prov #{u}", base_url: "http://localhost:1"})

      {:ok, _log} =
        Logs.log_request(%{
          group_member_id: member.id,
          user_id: owner.id,
          provider_id: provider.id,
          model_requested: "gpt-4o",
          model_responded: "gpt-4o",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 1_000,
          completion_tokens: 500,
          cache_read_tokens: 250,
          provider_cost_usd: "0.020",
          latency_ms: 42,
          streaming: false,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      %{user: admin, password: password} = register("admin")

      conn =
        conn
        |> login(admin, password)
        |> get(~p"/stats/export?type=finops&period=today")

      body = response(conn, 200)

      assert body =~
               "tipo,sujeto,requests,costo_usd,cost_per_req,tokens_in,tokens_out,cache_pct,errores,error_waste_usd,thinking_cost_usd,topup_cost_usd"

      row = body |> String.split("\n") |> Enum.find(&String.contains?(&1, owner.email))
      refute row == nil

      [tipo, _sujeto, requests, cost, cost_per_req, tokens_in, tokens_out, cache_pct | _] =
        String.split(row, ",")

      assert tipo == "user"
      assert requests == "1"
      assert cost == "0.020000"
      # 0.02 / 1 request, a la resolución del dinero.
      assert cost_per_req == "0.020000"
      assert tokens_in == "1000"
      assert tokens_out == "500"
      # 250 tokens de cache sobre 1000 de prompt.
      assert cache_pct == "25.0"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "estadisticas_finops_today_"
      assert disposition =~ ".csv"
    end

    test "non-admin gets 403", %{conn: conn} do
      %{user: plain, password: password} = register("user")

      conn =
        conn
        |> login(plain, password)
        |> get(~p"/stats/export?type=finops&period=today")

      assert json_response(conn, 403) == %{"error" => "no autorizado"}
    end
  end

  ## Router export ----------------------------------------------------------

  defp router_fixture do
    u = unique()
    {:ok, group} = Accounts.create_group(%{name: "Rt Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "rt-owner-#{u}@example.com",
        name: "Rt Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Rt Prov #{u}", base_url: "http://localhost:1"})

    {:ok, model} = Providers.create_model(%{name: "rt-model-#{u}", context_window: 128_000})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        user_id: owner.id,
        provider_id: provider.id,
        model_id: model.id,
        model_requested: model.name,
        model_resolved: model.name,
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 1_000,
        completion_tokens: 500,
        provider_cost_usd: "0.020",
        latency_ms: 1_000,
        ttft_ms: 200,
        streaming: false,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        routed_via_router: true,
        router_use_case_key: "coding_implement",
        router_effort_tier: "high",
        router_decision_source: "classifier",
        router_decision_ms: 120,
        router_decision_cost_usd: "0.010",
        router_baseline_cost_usd: "0.030"
      })

    %{model: model}
  end

  describe "router export" do
    test "admin: use cases by default, model performance with view=models", %{conn: conn} do
      %{model: model} = router_fixture()
      %{user: admin, password: password} = register("admin")

      conn = conn |> login(admin, password)

      use_conn = get(conn, ~p"/stats/export?type=router&period=today")

      [disposition] = get_resp_header(use_conn, "content-disposition")
      assert disposition =~ "estadisticas_router_today_"
      use_cases = response(use_conn, 200)

      assert use_cases =~ "caso_uso,effort_tier,requests"
      assert use_cases =~ "coding_implement"
      assert use_cases =~ "high"

      models = response(get(conn, ~p"/stats/export?type=router&period=today&view=models"), 200)

      assert models =~ "modelo,requests,costo_usd"
      assert models =~ model.name
    end

    test "non-admin gets 403", %{conn: conn} do
      %{user: plain, password: password} = register("user")

      conn =
        conn
        |> login(plain, password)
        |> get(~p"/stats/export?type=router&period=today")

      assert json_response(conn, 403) == %{"error" => "no autorizado"}
    end
  end

  ## Ordering and filenames -------------------------------------------------

  describe "sort, direction and filename" do
    test "sort/direction reorder the exported rows", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      tag = Integer.to_string(unique())

      cheap = "Svc cheap #{tag}"
      pricy = "Svc pricy #{tag}"

      for {name, cost} <- [{cheap, "0.001"}, {pricy, "0.500"}] do
        {:ok, service} = Accounts.create_service(%{name: name})

        {:ok, provider} =
          Providers.create_provider(%{name: "P #{name}", base_url: "http://localhost:1"})

        {:ok, _} =
          Logs.log_request(%{
            subject_type: "service",
            service_id: service.id,
            provider_id: provider.id,
            model_requested: "gpt-4o",
            status_code: 200,
            prompt_tokens: 10,
            completion_tokens: 5,
            provider_cost_usd: cost,
            latency_ms: 42,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
      end

      conn = conn |> login(admin, password)

      costs =
        fn query ->
          conn
          |> get(query)
          |> response(200)
          |> String.split("\n")
          |> Enum.drop(1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.filter(&String.contains?(&1, tag))
          |> Enum.map(fn row -> row |> String.split(",") |> Enum.at(2) end)
        end

      assert costs.(~p"/stats/export?type=services&period=today&sort=cost&direction=asc") ==
               ["0.001000", "0.500000"]

      assert costs.(~p"/stats/export?type=services&period=today&sort=cost&direction=desc") ==
               ["0.500000", "0.001000"]

      # Sin `sort` el orden del agregado queda intacto (no se ordena por otra
      # columna "en silencio").
      assert length(costs.(~p"/stats/export?type=services&period=today")) == 2

      priced = get(conn, ~p"/stats/export?type=services&period=today")

      [disposition] = get_resp_header(priced, "content-disposition")
      assert disposition =~ "estadisticas_servicios_today_"
    end
  end
end
