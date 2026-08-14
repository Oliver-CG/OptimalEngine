defmodule OptimalEngine.API.MemoryMetadataTest do
  # Caller metadata on the claim-create path (POST /api/memory).
  #
  # The pass-through itself is existing behaviour: the router accepts a
  # "metadata" object, governed_memory_metadata/4 merges it, and the
  # ClaimExtractor stamps it onto the pending claim. The first two tests PIN
  # that path — downstream cockpits key on `metadata.feit_concept` to decide
  # whether a claim is reviewable, so silently losing it would not fail loudly
  # anywhere else. The last two tests cover the new fail-closed edge: a
  # non-object or oversized metadata body is a loud 400, not a silent %{}
  # (normalize_metadata/1 swallows non-maps) and not an unbounded write.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router

  @opts Router.init([])

  defp request(method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    Router.call(conn, @opts)
  end

  defp fresh_workspace, do: "meta-toets-#{System.unique_integer([:positive])}"

  defp enige_claim(workspace) do
    review = request(:get, "/api/memory-core/claim-review?workspace=#{workspace}")
    assert review.status == 200
    %{"claims" => [claim]} = Jason.decode!(review.resp_body)
    claim
  end

  describe "caller metadata op het claim-create-pad" do
    test "feit_concept rijdt mee op de pending claim, naast de engine-metadata" do
      ws = fresh_workspace()

      conn =
        request(:post, "/api/memory", %{
          content: "De keukenproductiviteit was 71 euro per uur.",
          workspace: ws,
          metadata: %{
            feit_concept: %{
              pijler: "zaak",
              soort: "productiviteit",
              cijfers: [71],
              eigenaar: "keuken"
            }
          }
        })

      assert conn.status == 201

      claim = enige_claim(ws)
      assert claim["metadata"]["feit_concept"]["pijler"] == "zaak"
      assert claim["metadata"]["feit_concept"]["cijfers"] == [71]
      assert claim["metadata"]["memory_intake"]["path"] == "memory_core_pending_claim"
    end

    test "engine-sleutels winnen van caller-metadata" do
      ws = fresh_workspace()

      conn =
        request(:post, "/api/memory", %{
          content: "Een bewering met een vervalste intake-sleutel.",
          workspace: ws,
          metadata: %{memory_intake: %{path: "vervalst"}}
        })

      assert conn.status == 201

      claim = enige_claim(ws)
      assert claim["metadata"]["memory_intake"]["path"] == "memory_core_pending_claim"
    end

    test "metadata die geen JSON-object is -> 400, geen stille %{}" do
      conn =
        request(:post, "/api/memory", %{
          content: "Een bewering.",
          workspace: fresh_workspace(),
          metadata: "gewoon een string"
        })

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "object"
    end

    test "metadata boven de encoded-grens -> 400" do
      conn =
        request(:post, "/api/memory", %{
          content: "Een bewering.",
          workspace: fresh_workspace(),
          metadata: %{feit_concept: %{blob: String.duplicate("a", 20_000)}}
        })

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "large"
    end
  end
end
