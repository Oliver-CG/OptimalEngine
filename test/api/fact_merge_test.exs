defmodule OptimalEngine.API.FactMergeTest do
  @moduledoc """
  POST /api/memory-core/facts/merge: twee of meer geldende feiten worden één.

  Waarom (Nikki, 23-09): de feiten zijn veel en lijken op elkaar. De schil
  krijgt een knop "Voeg samen"; deze route is wat die knop aanroept.

  Wat deze toetsen vastleggen:
  · het nieuwe feit draagt de opgegeven tekst en is het enige geldende;
  · elk oud feit is superseded met `superseded_by` = het nieuwe id, dus de
    keten is dezelfde als bij een herziening (PATCH) en de schil verhuist de
    bevestigingen van de zaak langs die keten (U9, `geldendFeitId`);
  · de reden blijft in de historie: op de oude rijen, op de nieuwe rij en in
    het derivation-ledger;
  · `?droog=1` toont precies wat er zou gebeuren en schrijft niets;
  · minder dan twee feiten, lege tekst, geen reden, een feit uit een andere
    zaak of een feit dat niet meer geldt: er gebeurt niets.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.MemoryCore.{Fact, Store}

  @opts Router.init([])

  # Elk verzoek draagt een eigen sleutel: de rate limiter emmert anoniem per
  # IP en die emmer deelt de hele suite (zie claim_retraction_test.exs).
  setup do
    OptimalEngine.API.RateLimiter.reset()
    :ok
  end

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
        name: "merge-test-#{System.unique_integer([:positive])}",
        principal_id: principal_id
      })

    token
  end

  defp lezer do
    case Process.get(:samenvoegen_lezer) do
      nil ->
        token = principal_token("user:lezer-#{System.unique_integer([:positive])}")
        Process.put(:samenvoegen_lezer, token)
        token

      token ->
        token
    end
  end

  defp keurder do
    case Process.get(:samenvoegen_keurder) do
      nil ->
        token = principal_token("user:keurder-#{System.unique_integer([:positive])}")
        Process.put(:samenvoegen_keurder, token)
        token

      token ->
        token
    end
  end

  defp signed(method, path, body, token) do
    case body do
      nil ->
        conn(method, path)

      b ->
        conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
    end
    |> put_req_header("x-api-key", token)
    |> Router.call(@opts)
  end

  defp get_json(path) do
    conn = signed(:get, path, nil, lezer())
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp merge(ws, body, query \\ "") do
    signed(:post, "/api/memory-core/facts/merge?workspace=#{ws}#{query}", body, keurder())
  end

  # N geldende feiten in één zaak, elk langs de echte weg: claim, keuring,
  # promotie. Zo draagt elk feit zijn eigen claim en bewijslinks.
  defp geldende_feiten(ws, n) do
    feiten =
      for i <- 1..n do
        content = "Zaalhuur regel #{i} variant #{System.unique_integer([:positive])}"

        create =
          signed(:post, "/api/memory", %{"workspace" => ws, "content" => content}, lezer())

        assert create.status == 201

        %{"claims" => claims} = get_json("/api/memory-core/claims?workspace=#{ws}")
        claim = Enum.find(claims, &(&1["claim_text"] =~ content))
        assert claim, "geen claim gevonden voor #{content}"

        promote =
          signed(
            :post,
            "/api/memory-core/claims/#{claim["id"]}/promote",
            %{"workspace" => ws, "fact_text" => "Feit #{i}: #{content}"},
            keurder()
          )

        assert promote.status == 200
        Jason.decode!(promote.resp_body)["fact"]
      end

    # Precondities: alle N gelden. Anders meet de rest van de toets niets.
    %{"count" => count} = get_json("/api/memory-core/facts?workspace=#{ws}&current_only=1")
    assert count == n
    feiten
  end

  defp tel(sql, params) do
    {:ok, [[n]]} = OptimalEngine.Store.raw_query(sql, params)
    n
  end

  # Alles wat een samenvoeging zou schrijven, als één vingerafdruk.
  defp stand(ws) do
    %{
      feiten: tel("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [ws]),
      geldend:
        tel("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1 AND transaction_time_end IS NULL", [
          ws
        ]),
      ledger: tel("SELECT COUNT(*) FROM derivation_ledger WHERE workspace_id = ?1", [ws]),
      edges: tel("SELECT COUNT(*) FROM relationship_edges WHERE workspace_id = ?1", [ws])
    }
  end

  describe "POST /api/memory-core/facts/merge" do
    test "drie geldende feiten worden één nieuw feit, de oude wijzen ernaar" do
      ws = "samenvoegen-#{System.unique_integer([:positive])}"
      [a, b, c] = geldende_feiten(ws, 3)
      ids = [a["id"], b["id"], c["id"]]
      reden = "drie keer dezelfde zaalhuur, Nikki 23-09"

      conn =
        merge(ws, %{
          "fact_ids" => ids,
          "fact_text" => "De zaalhuur is 450 euro per dagdeel",
          "reason" => reden
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["droog"] == false
      nieuw = body["fact"]
      assert is_binary(nieuw["id"])
      refute nieuw["id"] in ids
      assert nieuw["fact_text"] == "De zaalhuur is 450 euro per dagdeel"
      assert nieuw["lifecycle_state"] == "accepted"
      assert nieuw["verification_status"] == "reviewed"
      assert nieuw["supersedes"] == ids
      assert nieuw["transaction_time_end"] == nil

      # De lineage van alle drie reist mee: elke claim die een oud feit droeg.
      claims = Enum.flat_map([a, b, c], & &1["accepted_claim_ids"])
      assert Enum.sort(nieuw["accepted_claim_ids"]) == Enum.sort(claims)

      assert Enum.map(body["old_facts"], & &1["id"]) == ids
      assert Enum.all?(body["old_facts"], &(&1["superseded_by"] == nieuw["id"]))

      # De geldende lezing (het filter van de schil): precies één feit.
      geldend = get_json("/api/memory-core/facts?workspace=#{ws}&current_only=1")
      assert geldend["count"] == 1
      assert [%{"id" => nieuw_id}] = geldend["facts"]
      assert nieuw_id == nieuw["id"]

      # De keten zoals de schil hem leest (`haalVervangenFeiten`): elke oude
      # rij superseded, met superseded_by naar het nieuwe feit.
      vervangen =
        get_json("/api/memory-core/facts?workspace=#{ws}&lifecycle_state=superseded")

      assert vervangen["count"] == 3

      for oud <- vervangen["facts"] do
        assert oud["id"] in ids
        assert oud["superseded_by"] == nieuw["id"]
        assert oud["transaction_time_end"] != nil
        # De reden blijft op de oude rij.
        assert oud["metadata"]["supersession_reason"] == reden
      end

      # En op de nieuwe rij, en in het ledger.
      assert nieuw["metadata"]["merge_reason"] == reden
      assert nieuw["metadata"]["merged_from"] == ids

      assert tel(
               "SELECT COUNT(*) FROM derivation_ledger WHERE workspace_id = ?1 AND activity_type = 'memory_core.merge_facts' AND metadata LIKE ?2",
               [ws, "%#{reden}%"]
             ) == 1

      # Een supersedes-edge per oud feit, net als bij een herziening.
      assert tel(
               "SELECT COUNT(*) FROM relationship_edges WHERE workspace_id = ?1 AND relationship_type = 'supersedes' AND from_object_id = ?2",
               [ws, nieuw["id"]]
             ) == 3
    end

    test "een herzien feit samenvoegen verlengt de keten, zodat een bevestiging meeloopt" do
      ws = "samenvoegen-keten-#{System.unique_integer([:positive])}"
      [a, b] = geldende_feiten(ws, 2)

      herzien =
        signed(
          :patch,
          "/api/memory-core/facts/#{a["id"]}?workspace=#{ws}",
          %{"fact_text" => "Feit a, herzien", "reason" => "bronlabel"},
          keurder()
        )

      assert herzien.status == 200
      a2 = Jason.decode!(herzien.resp_body)["fact"]

      conn =
        merge(ws, %{
          "fact_ids" => [a2["id"], b["id"]],
          "fact_text" => "Eén feit uit a en b",
          "reason" => "zelfde strekking"
        })

      assert conn.status == 200
      nieuw_id = Jason.decode!(conn.resp_body)["fact"]["id"]

      opvolgers =
        get_json("/api/memory-core/facts?workspace=#{ws}&lifecycle_state=superseded")["facts"]
        |> Map.new(&{&1["id"], &1["superseded_by"]})

      # Een Klopt op het allereerste id van a komt via a2 op het nieuwe feit uit.
      assert opvolgers[a["id"]] == a2["id"]
      assert opvolgers[a2["id"]] == nieuw_id
      assert opvolgers[b["id"]] == nieuw_id
    end

    test "droog toont wat er zou gebeuren en schrijft niets" do
      ws = "samenvoegen-droog-#{System.unique_integer([:positive])}"
      [a, b] = geldende_feiten(ws, 2)
      voor = stand(ws)

      conn =
        merge(
          ws,
          %{
            "fact_ids" => [a["id"], b["id"]],
            "fact_text" => "Samen één feit",
            "reason" => "proef"
          },
          "&droog=1"
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["droog"] == true
      assert body["fact"]["fact_text"] == "Samen één feit"
      assert body["fact"]["supersedes"] == [a["id"], b["id"]]
      # Er komt geen feit, dus ook geen id om naar te wijzen.
      assert body["fact"]["id"] == nil
      assert Enum.map(body["old_facts"], & &1["id"]) == [a["id"], b["id"]]
      assert Enum.map(body["old_facts"], & &1["fact_text"]) == [a["fact_text"], b["fact_text"]]

      # Het bewijs is de database: niets erbij, niets gesloten.
      assert stand(ws) == voor

      geldend = get_json("/api/memory-core/facts?workspace=#{ws}&current_only=1")
      assert Enum.sort(Enum.map(geldend["facts"], & &1["id"])) == Enum.sort([a["id"], b["id"]])
    end

    test "minder dan twee feiten is 400 en laat alles staan" do
      ws = "samenvoegen-een-#{System.unique_integer([:positive])}"
      [a, _b] = geldende_feiten(ws, 2)
      voor = stand(ws)

      een = merge(ws, %{"fact_ids" => [a["id"]], "fact_text" => "x", "reason" => "y"})
      assert een.status == 400

      # Hetzelfde id twee keer is nog steeds één feit.
      dubbel =
        merge(ws, %{"fact_ids" => [a["id"], a["id"]], "fact_text" => "x", "reason" => "y"})

      assert dubbel.status == 400

      geen = merge(ws, %{"fact_text" => "x", "reason" => "y"})
      assert geen.status == 400

      assert stand(ws) == voor
    end

    test "lege tekst of geen reden is 400 en laat alles staan" do
      ws = "samenvoegen-leeg-#{System.unique_integer([:positive])}"
      [a, b] = geldende_feiten(ws, 2)
      voor = stand(ws)
      ids = [a["id"], b["id"]]

      leeg = merge(ws, %{"fact_ids" => ids, "fact_text" => "   ", "reason" => "y"})
      assert leeg.status == 400

      zonder_tekst = merge(ws, %{"fact_ids" => ids, "reason" => "y"})
      assert zonder_tekst.status == 400

      zonder_reden = merge(ws, %{"fact_ids" => ids, "fact_text" => "samen"})
      assert zonder_reden.status == 400
      assert Jason.decode!(zonder_reden.resp_body)["error"] == "reason_required"

      blanco_reden = merge(ws, %{"fact_ids" => ids, "fact_text" => "samen", "reason" => "  "})
      assert blanco_reden.status == 400

      assert stand(ws) == voor
    end

    test "een feit uit een andere zaak is 404 en laat beide zaken staan" do
      ws = "samenvoegen-zaak-#{System.unique_integer([:positive])}"
      ander = "samenvoegen-ander-#{System.unique_integer([:positive])}"
      [a] = geldende_feiten(ws, 1)
      [x] = geldende_feiten(ander, 1)
      voor = {stand(ws), stand(ander)}

      conn = merge(ws, %{"fact_ids" => [a["id"], x["id"]], "fact_text" => "x", "reason" => "y"})

      assert conn.status == 404
      # Niet zomaar 404: de catch-all van de router antwoordt óók 404.
      assert %{"error" => "not_found", "fact_id" => fact_id} = Jason.decode!(conn.resp_body)
      assert fact_id == x["id"]
      assert {stand(ws), stand(ander)} == voor
    end

    test "een feit dat niet meer geldt is 409 en de rest blijft staan" do
      ws = "samenvoegen-oud-#{System.unique_integer([:positive])}"
      [a, b] = geldende_feiten(ws, 2)

      herzien =
        signed(
          :patch,
          "/api/memory-core/facts/#{a["id"]}?workspace=#{ws}",
          %{"fact_text" => "a herzien", "reason" => "correctie"},
          keurder()
        )

      assert herzien.status == 200
      voor = stand(ws)

      conn = merge(ws, %{"fact_ids" => [a["id"], b["id"]], "fact_text" => "x", "reason" => "y"})
      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["fact_id"] == a["id"]
      assert is_binary(body["superseded_by"])

      assert stand(ws) == voor
    end

    test "feiten met een ander toegangsbeleid worden niet één feit" do
      ws = "samenvoegen-beleid-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      [open, dicht] =
        for {policy, i} <- [{nil, 1}, {"policy:alleen-keuken", 2}] do
          fact =
            Fact.new(%{
              id: "fact_beleid_#{i}_#{System.unique_integer([:positive])}",
              workspace_id: ws,
              fact_text: "beleidsfeit #{i}",
              lifecycle_state: "accepted",
              access_policy_id: policy,
              transaction_time_start: now
            })

          :ok = Store.insert_fact(fact)
          fact
        end

      voor = stand(ws)

      conn =
        merge(ws, %{"fact_ids" => [open.id, dicht.id], "fact_text" => "x", "reason" => "y"})

      assert conn.status == 422
      assert stand(ws) == voor
    end
  end
end
