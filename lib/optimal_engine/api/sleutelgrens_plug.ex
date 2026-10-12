defmodule OptimalEngine.API.SleutelgrensPlug do
  @moduledoc """
  De sleutelgrens (L1.9): een sleutel die geen beheersleutel is, komt alleen
  bij de routes van zijn rol. Draait na `AuthPlug`, vóór `:dispatch`.

  Waarom (gemeten 09-10): open claims kwamen terug via `/api/search` en
  `/api/grep`. Een claim wordt geplaatst als memory (`POST /api/memory`), dus
  elke route die memories, chunks, bronnen of exports leest, draagt de
  ongekeurde tekst. Per route filteren is een denylist in een router van
  vijfduizend regels; daarom een toegangslijst per rol, die dicht valt.

  Drie rollen, naar de scopes op de sleutel:

  * **beheersleutel** (`admin` of `*`): alles. Box-only.
  * **werksleutel** (`write`, geen beheer): claims plaatsen, keuren, de
    keurlijst lezen en feiten herzien. De keurlijst toont open claims aan wie
    keurt; dat is haar werk. De ruwe zoek- en leespaden niet:
    403 `beheersleutel_vereist`.
  * **agentsleutel** (al het andere, zoals de leessleutels uit
    `deploy/mint_read_keys.exs`): alleen gekeurde, geldende feiten. De
    feitenlijst krijgt `lifecycle_state=accepted` en `current_only=1`
    opgelegd; de keurlijst alleen met `review_status=approved`, en de route
    geeft dan per claim alleen de huidige tekst van het geldende feit (zie
    `claim-review` in de router). Al het andere: 403 `alleen_gekeurde_feiten`.

  Zonder sleutel (alleen mogelijk met `auth_required: false`, de dev-stand)
  geldt geen rol, net als bij `admin_scope?/1` in de router.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{halted: true} = conn, _opts), do: conn

  def call(conn, _opts) do
    case rol(conn.assigns[:current_api_key]) do
      :geen -> conn
      :beheer -> conn
      :werk -> werk(conn)
      # De rol gaat mee naar de route: `claim-review` geeft een agent alleen de
      # tekst van het geldende feit (L1.9b).
      :agent -> conn |> assign(:sleutelrol, :agent) |> agent()
    end
  end

  @doc false
  def rol(nil), do: :geen

  def rol(%{scopes: scopes}) when is_list(scopes) do
    cond do
      "admin" in scopes or "*" in scopes -> :beheer
      "write" in scopes -> :werk
      true -> :agent
    end
  end

  def rol(_), do: :agent

  # ── werksleutel ───────────────────────────────────────────────────────────

  defp werk(conn) do
    if werk_pad?(methode(conn), conn.path_info),
      do: conn,
      else: weiger(conn, "beheersleutel_vereist")
  end

  defp werk_pad?(m, pad) do
    algemeen_pad?(m, pad) or
      case {m, pad} do
        {"POST", ["api", "memory"]} ->
          true

        {"GET", ["api", "memory-core", "claims"]} ->
          true

        {"GET", ["api", "memory-core", "claims", _id]} ->
          true

        {"POST", ["api", "memory-core", "claims", _id, actie]} ->
          actie in ~w(promote reject retract)

        {"GET", ["api", "memory-core", "claim-review"]} ->
          true

        {"GET", ["api", "memory-core", "facts"]} ->
          true

        {"PATCH", ["api", "memory-core", "facts", _id]} ->
          true

        {"POST", ["api", "memory-core", "facts", "merge"]} ->
          true

        {"POST", ["api", "memory-core", "facts", "search"]} ->
          true

        _ ->
          false
      end
  end

  # ── agentsleutel ──────────────────────────────────────────────────────────

  defp agent(conn) do
    m = methode(conn)

    cond do
      algemeen_pad?(m, conn.path_info) ->
        conn

      {m, conn.path_info} == {"POST", ["api", "memory-core", "facts", "search"]} ->
        conn

      {m, conn.path_info} == {"GET", ["api", "memory-core", "facts"]} ->
        alleen_geldende_feiten(conn)

      {m, conn.path_info} == {"GET", ["api", "memory-core", "claim-review"]} ->
        alleen_goedgekeurde_claims(conn)

      true ->
        weiger(conn, "alleen_gekeurde_feiten")
    end
  end

  # De feitenlijst draagt ook vervangen, ingetrokken en ongekeurde rijen. Een
  # agent krijgt alleen de geldende gekeurde; vraagt hij om een andere stand,
  # dan is dat een weigering en geen stille andere lijst.
  defp alleen_geldende_feiten(conn) do
    conn = fetch_query_params(conn)

    case Map.get(conn.query_params, "lifecycle_state") do
      nil -> leg_op(conn, %{"lifecycle_state" => "accepted", "current_only" => "1"})
      "accepted" -> leg_op(conn, %{"lifecycle_state" => "accepted", "current_only" => "1"})
      _ -> weiger(conn, "alleen_gekeurde_feiten")
    end
  end

  defp alleen_goedgekeurde_claims(conn) do
    conn = fetch_query_params(conn)

    if Map.get(conn.query_params, "review_status") == "approved",
      do: conn,
      else: weiger(conn, "alleen_gekeurde_feiten")
  end

  defp leg_op(conn, opgelegd) do
    query_params = Map.merge(conn.query_params, opgelegd)

    params = if is_map(conn.params), do: Map.merge(conn.params, opgelegd), else: opgelegd

    %{
      conn
      | query_params: query_params,
        query_string: URI.encode_query(query_params),
        params: params
    }
  end

  # ── gedeeld ───────────────────────────────────────────────────────────────

  defp algemeen_pad?("OPTIONS", _), do: true
  defp algemeen_pad?("GET", ["api", "health"]), do: true
  defp algemeen_pad?("GET", ["api", "status"]), do: true
  defp algemeen_pad?("GET", ["api", "metrics", "prometheus"]), do: true
  defp algemeen_pad?(_, _), do: false

  # Plug.Router laat `get` ook HEAD bedienen.
  defp methode(%{method: "HEAD"}), do: "GET"
  defp methode(%{method: m}), do: m

  defp weiger(conn, reden) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: reden}))
    |> halt()
  end
end
