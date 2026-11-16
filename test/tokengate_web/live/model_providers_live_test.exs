defmodule TokengateWeb.ModelProvidersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "lanes-#{u}@example.com",
        name: "User #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp create_provider(attrs \\ %{}) do
    u = unique()

    {:ok, provider} =
      Providers.create_provider(
        Map.merge(%{name: "Prov #{u}", base_url: "https://api-#{u}.example.com/v1"}, attrs)
      )

    provider
  end

  defp create_model(attrs \\ %{}) do
    u = unique()

    {:ok, model} =
      Providers.create_model(Map.merge(%{name: "model-#{u}", context_window: 128_000}, attrs))

    model
  end

  defp create_credential(provider) do
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "Key #{unique()}",
        api_key_encrypted: "sk-test-abcd",
        status: "active"
      })

    credential
  end

  defp create_lane(model, provider, attrs \\ %{}) do
    credential = create_credential(provider)

    {:ok, lane} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_id: model.id,
            credential_id: credential.id,
            provider_model: "upstream/#{unique()}",
            priority: 1,
            enabled: true
          },
          attrs
        )
      )

    lane
  end

  ## Permissions -----------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    model = create_model()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/catalog/models/#{model.id}")
  end

  test "non-admin users are redirected to /dashboard", %{conn: conn} do
    model = create_model()
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/catalog/models/#{model.id}")
  end

  # Un id inexistente (o que ni siquiera es UUID) cae en el listado, no revienta.
  test "an unknown model id falls back to the models list", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/catalog/models"}}} =
             live(conn, ~p"/catalog/models/2f1c2b1e-0000-4000-8000-000000000000")

    assert {:error, {:redirect, %{to: "/catalog/models"}}} =
             live(conn, "/catalog/models/no-es-un-uuid")
  end

  ## La página -------------------------------------------------------------

  test "lists the lanes of THIS model only", %{conn: conn} do
    model = create_model()
    other = create_model()
    lane = create_lane(model, create_provider())
    foreign = create_lane(other, create_provider())

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    assert has_element?(view, "table#lanes-table")
    assert has_element?(view, "#model-provider-#{lane.id}")
    refute has_element?(view, "#model-provider-#{foreign.id}")
    refute has_element?(view, "#lanes-empty")
  end

  test "a model with no lanes shows the empty state", %{conn: conn} do
    model = create_model()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    assert has_element?(view, "#lanes-empty")
    assert has_element?(view, "#new-ap-#{model.id}")
  end

  # El alta de un lane abre con la unidad de precio del TIPO del modelo y con el
  # modelo ya fijado en el form.
  test "the assign modal opens with the model and its type unit", %{conn: conn} do
    model = create_model(%{model_type: "image"})
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}")

    view |> element("#new-ap-#{model.id}") |> render_click()

    assert has_element?(view, "#model-provider-form")

    # La unidad nace con la del TIPO del modelo: un lane de imagen abre en
    # «por imagen», no en tokens.
    assert has_element?(
             view,
             "#model-provider-form select[name='model_provider[pricing_unit]'] option[selected][value='per_image']"
           )
  end

  test "?edit=<lane> opens that lane's form", %{conn: conn} do
    model = create_model()
    lane = create_lane(model, create_provider(), %{provider_model: "upstream/preset"})
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/catalog/models/#{model.id}?edit=#{lane.id}")

    assert has_element?(view, "#model-provider-form")
    assert has_element?(view, "#model-provider-form input[value='upstream/preset']")
  end

  ## Contadores del listado (helpers puros) --------------------------------

  test "lane_count and lane_provider_count read the preloaded lanes" do
    model = create_model()
    provider = create_provider()
    _lane = create_lane(model, provider)
    _lane2 = create_lane(model, provider)

    _ = {model, provider}

    assert TokengateWeb.ModelsLive.lane_count(%{model_providers: []}) == 0
    assert TokengateWeb.ModelsLive.lane_count(%{model_providers: [%{}, %{}]}) == 2

    assert TokengateWeb.ModelsLive.lane_provider_count(%{
             model_providers: [
               %{credential_id: "a"},
               %{credential_id: "a"},
               %{credential_id: "b"}
             ]
           }) == 2
  end

  test "price_summary: cheapest lane, mixed units, and no price" do
    alias TokengateWeb.ModelsLive

    # Sin precios capturados.
    assert ModelsLive.price_summary(%{model_providers: [%{pricing_unit: "per_1m_tokens"}]}) == nil

    # Todas en la misma unidad: gana la más barata.
    lanes = [
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("3.5")},
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("1.25")}
    ]

    assert {unit, amount} = ModelsLive.price_summary(%{model_providers: lanes})
    assert unit == "per_1m_tokens"
    assert Decimal.equal?(amount, Decimal.new("1.25"))

    # Unidades distintas: no hay número comparable.
    mixed = [
      %{pricing_unit: "per_1m_tokens", input_cost_per_million: Decimal.new("1")},
      %{pricing_unit: "per_image", unit_cost: Decimal.new("0.04")}
    ]

    assert ModelsLive.price_summary(%{model_providers: mixed}) == :mixed

    # Un lane por unidad cobra su propio campo.
    assert {"per_image", %Decimal{}} =
             ModelsLive.price_summary(%{
               model_providers: [%{pricing_unit: "per_image", unit_cost: Decimal.new("0.04")}]
             })
  end

  ## El listado cuenta y enlaza -------------------------------------------

  test "the list row counts its keys and links to the model page", %{conn: conn} do
    model = create_model(%{name: "listado-lane-#{unique()}"})
    provider = create_provider()
    _lane = create_lane(model, provider)
    _lane2 = create_lane(model, provider)

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/catalog/models")

    assert has_element?(
             view,
             "a#model-keys-#{model.id}[href='/catalog/models/#{model.id}']",
             "2"
           )
  end
end
