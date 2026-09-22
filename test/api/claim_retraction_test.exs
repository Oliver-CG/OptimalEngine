defmodule OptimalEngine.API.ClaimRetractionTest do
  @moduledoc """
  POST /api/memory-core/claims/:id/retract — een gepromoveerde claim intrekken
  met wie en waarom.

  Het gat dat dit sluit (gemeten 22-09): `claims/:id/reject` antwoordt op een
  gepromoveerde claim `409 claim_already_promoted`, en er was geen enkele route
  die een feit uit beeld haalt. De schil hing daardoor een eigen intrekkingen-
  tabel naast de engine; het brein zelf bleef het feit gewoon dragen, dus elke
  andere lezer (agentbeurt, RAG, een tweede schil) zag de ingetrokken zin nog.

  Wat deze toetsen vastleggen:
  · de claim gaat naar lifecycle/review "retracted", mét reden en keurder;
  · het feit dat eruit voortkwam wordt gesloten (`transaction_time_end`), dus
    `current_only=1` levert het niet meer — precies het filter dat de schil
    gebruikt (`haalFeiten` in lib/bibliothecaris/engine.ts);
  · de historie blijft leesbaar: de rij staat er nog, met reden en keurder;
  · de terugvalroute van de schil (`claim-review?review_status=approved`)
    levert de claim niet meer, want lifecycle is niet langer "promoted";
  · zonder reden, zonder principal, of twee keer: geen intrekking.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router

  @opts Router.init([])

  # ══ WAAROM ELK VERZOEK HIER EEN SLEUTEL DRAAGT ══
  # De rate limiter emmert per api-sleutel (`key:<id>`) en valt zonder sleutel
  # terug op één emmer per IP — en die ip-emmer is GEDEELD met de hele suite.
  # Gemeten 22-09 op kale higgi/main: een extra module die niets anders doet
  # dan 49 gewone GET's maakt bij seed 663685 24 toetsen in `router_test`
  # rood met 429. De suite zit dus tegen die begroting aan; een nieuwe
  # toetsmodule die er anoniem bij komt, tipt hem om. Een eigen sleutel per
  # toets is een eigen emmer, dus deze module telt niet mee in die begroting.
  # (De fragiliteit zelf blijft staan en is gemeld — hij is ouder dan deze baan.)
  setup do
    # En de ip-emmer krijgt zijn tokens terug, zodat de ene anonieme aanroep
    # hieronder (de 403-toets) niet afhangt van wie er toevallig vóór draaide.
    OptimalEngine.API.RateLimiter.reset()
    :ok
  end

  defp lezer_sleutel do
    case Process.get(:intrekken_lezer_sleutel) do
      nil ->
        token = principal_token("user:lezer-#{System.unique_integer([:positive])}")
        Process.put(:intrekken_lezer_sleutel, token)
        token

      token ->
        token
    end
  end

  defp request(method, path, body \\ nil) do
    case body do
      nil ->
        conn(method, path)

      b ->
        conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
    end
    |> put_req_header("x-api-key", lezer_sleutel())
    |> Router.call(@opts)
  end

  # De enige aanroep zónder sleutel: de toets die bewijst dat anoniem intrekken
  # niet kan.
  defp zonder_sleutel(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp signed(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-api-key", token)
    |> Router.call(@opts)
  end

  defp reviewer_token(principal_id), do: principal_token(principal_id)

  defp principal_token(principal_id) do
    {:ok, _} =
      OptimalEngine.Identity.Principal.upsert(%{
        id: principal_id,
        kind: :user,
        display_name: principal_id
      })

    {:ok, %{key: token}} =
      OptimalEngine.Auth.ApiKey.mint(%{
        tenant_id: "default",
        name: "retract-test-#{System.unique_integer([:positive])}",
        principal_id: principal_id
      })

    token
  end

  # Een claim die op keuring wacht, in zijn eigen werkruimte.
  defp pending_claim(workspace_id) do
    content = "Toegang tot de keurlijst loopt via #{System.unique_integer([:positive])}"

    create = request(:post, "/api/memory", %{"workspace" => workspace_id, "content" => content})
    assert create.status == 201

    list = request(:get, "/api/memory-core/claims?workspace=#{workspace_id}")
    {:ok, %{"claims" => [claim]}} = Jason.decode(list.resp_body)
    {claim, content}
  end

  # Een gepromoveerde claim plus het feit dat eruit voortkwam.
  defp promoted_claim(workspace_id) do
    {claim, content} = pending_claim(workspace_id)
    token = reviewer_token("user:keurder-#{System.unique_integer([:positive])}")

    promote =
      signed(
        :post,
        "/api/memory-core/claims/#{claim["id"]}/promote",
        %{"workspace" => workspace_id, "fact_text" => "Geaccepteerd: #{content}"},
        token
      )

    assert promote.status == 200
    {:ok, %{"fact" => fact}} = Jason.decode(promote.resp_body)
    {claim, fact, token}
  end

  describe "POST /api/memory-core/claims/:id/retract" do
    test "trekt de claim in, sluit het feit, en houdt de historie leesbaar" do
      ws = "intrekken-#{System.unique_integer([:positive])}"
      {claim, fact, token} = promoted_claim(ws)

      # Vóór de intrekking staat het feit gewoon in de geldende lezing.
      voor = request(:get, "/api/memory-core/facts?workspace=#{ws}&current_only=1")
      {:ok, voor_body} = Jason.decode(voor.resp_body)
      assert voor_body["count"] == 1

      retract =
        signed(
          :post,
          "/api/memory-core/claims/#{claim["id"]}/retract",
          %{"workspace" => ws, "reason" => "de toegangszin droeg het adres van de operator"},
          token
        )

      assert retract.status == 200
      {:ok, body} = Jason.decode(retract.resp_body)
      assert body["claim"]["lifecycle_state"] == "retracted"
      assert body["claim"]["review_status"] == "retracted"
      assert body["retracted_fact_ids"] == [fact["id"]]

      # De GET zegt hetzelfde als het antwoord — het bewijs is de rij.
      geget = request(:get, "/api/memory-core/claims/#{claim["id"]}?workspace=#{ws}")
      {:ok, claim_body} = Jason.decode(geget.resp_body)
      assert claim_body["lifecycle_state"] == "retracted"
      assert claim_body["review_status"] == "retracted"

      # Precies het filter dat de schil gebruikt: weg uit de geldende lezing.
      na = request(:get, "/api/memory-core/facts?workspace=#{ws}&current_only=1")
      {:ok, na_body} = Jason.decode(na.resp_body)
      assert na_body["count"] == 0
      refute Enum.any?(na_body["facts"], &(&1["id"] == fact["id"]))

      # De historie blijft: de rij staat er, mét wie en waarom.
      alles = request(:get, "/api/memory-core/facts?workspace=#{ws}")
      {:ok, alles_body} = Jason.decode(alles.resp_body)
      ingetrokken = Enum.find(alles_body["facts"], &(&1["id"] == fact["id"]))
      assert ingetrokken["lifecycle_state"] == "retracted"
      assert ingetrokken["transaction_time_end"] != nil
      assert ingetrokken["fact_text"] == fact["fact_text"]

      retractie = ingetrokken["metadata"]["retraction"]
      assert retractie["reason"] == "de toegangszin droeg het adres van de operator"
      assert retractie["by"] != nil
      assert retractie["at"] != nil

      # En de terugvalroute van de schil levert hem ook niet meer.
      terugval =
        request(:get, "/api/memory-core/claim-review?workspace=#{ws}&review_status=approved")

      {:ok, terugval_body} = Jason.decode(terugval.resp_body)
      refute Enum.any?(terugval_body["claims"], &(&1["id"] == claim["id"]))
    end

    test "de memory objects op dat feit zijn niet meer op te halen" do
      ws = "intrekken-mo-#{System.unique_integer([:positive])}"
      {claim, fact, token} = promoted_claim(ws)

      assert {:ok, [[1]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT COUNT(*) FROM memory_objects WHERE workspace_id = ?1 AND supersession_status = 'none' AND fact_links LIKE ?2",
                 [ws, "%#{fact["id"]}%"]
               )

      assert signed(
               :post,
               "/api/memory-core/claims/#{claim["id"]}/retract",
               %{"workspace" => ws, "reason" => "klopt niet"},
               token
             ).status == 200

      assert {:ok, [[0]]} =
               OptimalEngine.Store.raw_query(
                 "SELECT COUNT(*) FROM memory_objects WHERE workspace_id = ?1 AND supersession_status = 'none' AND fact_links LIKE ?2",
                 [ws, "%#{fact["id"]}%"]
               )
    end

    test "zonder reden gebeurt er niets" do
      ws = "intrekken-reden-#{System.unique_integer([:positive])}"
      {claim, _fact, token} = promoted_claim(ws)

      leeg =
        signed(:post, "/api/memory-core/claims/#{claim["id"]}/retract", %{"workspace" => ws}, token)

      assert leeg.status == 400
      assert {:ok, %{"error" => "reason_required"}} = Jason.decode(leeg.resp_body)

      blanco =
        signed(
          :post,
          "/api/memory-core/claims/#{claim["id"]}/retract",
          %{"workspace" => ws, "reason" => "   "},
          token
        )

      assert blanco.status == 400

      # De claim staat nog precies zoals hij stond.
      geget = request(:get, "/api/memory-core/claims/#{claim["id"]}?workspace=#{ws}")
      {:ok, claim_body} = Jason.decode(geget.resp_body)
      assert claim_body["lifecycle_state"] == "promoted"

      na = request(:get, "/api/memory-core/facts?workspace=#{ws}&current_only=1")
      {:ok, na_body} = Jason.decode(na.resp_body)
      assert na_body["count"] == 1
    end

    test "anoniem intrekken is 403 en laat alles staan" do
      ws = "intrekken-anoniem-#{System.unique_integer([:positive])}"
      {claim, _fact, _token} = promoted_claim(ws)

      anoniem =
        zonder_sleutel(:post, "/api/memory-core/claims/#{claim["id"]}/retract", %{
          "workspace" => ws,
          "reason" => "zomaar",
          "actor_id" => "user:aanvaller"
        })

      assert anoniem.status == 403
      assert {:ok, %{"error" => "reviewer_required"}} = Jason.decode(anoniem.resp_body)

      geget = request(:get, "/api/memory-core/claims/#{claim["id"]}?workspace=#{ws}")
      {:ok, claim_body} = Jason.decode(geget.resp_body)
      assert claim_body["lifecycle_state"] == "promoted"
    end

    test "twee keer intrekken is 409" do
      ws = "intrekken-twee-#{System.unique_integer([:positive])}"
      {claim, _fact, token} = promoted_claim(ws)

      eerste =
        signed(
          :post,
          "/api/memory-core/claims/#{claim["id"]}/retract",
          %{"workspace" => ws, "reason" => "eerste"},
          token
        )

      assert eerste.status == 200

      tweede =
        signed(
          :post,
          "/api/memory-core/claims/#{claim["id"]}/retract",
          %{"workspace" => ws, "reason" => "tweede"},
          token
        )

      assert tweede.status == 409
      assert {:ok, %{"error" => "claim_not_promoted"}} = Jason.decode(tweede.resp_body)
    end

    test "een claim die nog op keuring wacht wordt afgewezen, niet ingetrokken" do
      ws = "intrekken-pending-#{System.unique_integer([:positive])}"
      {claim, _content} = pending_claim(ws)
      token = reviewer_token("user:keurder-#{System.unique_integer([:positive])}")

      conn =
        signed(
          :post,
          "/api/memory-core/claims/#{claim["id"]}/retract",
          %{"workspace" => ws, "reason" => "nog niet gekeurd"},
          token
        )

      assert conn.status == 409
      assert {:ok, %{"error" => "claim_not_promoted"}} = Jason.decode(conn.resp_body)
    end

    test "404 op een claim die niet bestaat" do
      token = reviewer_token("user:keurder-#{System.unique_integer([:positive])}")

      conn =
        signed(
          :post,
          "/api/memory-core/claims/cl_bestaatniet/retract",
          %{"workspace" => "ws-leeg", "reason" => "weg ermee"},
          token
        )

      assert conn.status == 404
      # Niet zomaar 404: de catch-all van de router antwoordt óók 404, dus
      # zonder deze regel is deze toets groen op een engine die de route
      # helemaal niet kent.
      assert {:ok, %{"error" => "claim not found"}} = Jason.decode(conn.resp_body)
    end
  end
end
