defmodule OptimalEngine.API.FactRevisionTest do
  @moduledoc """
  PATCH /api/memory-core/facts/:id — the bitemporal fact revision route.

  The bug this closes (gemeten 21-09): the shell's brein page shows an edit
  flow, but the engine had no update endpoint at all, so Nikki's save of a
  corrected Hooikamer amount silently vanished. These tests pin the contract:
  old row superseded (never mutated), new row current, lineage linked, and
  the old text still readable for history.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router

  @opts Router.init([])

  defp request(method, path, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    Router.call(conn, @opts)
  end

  # A current accepted fact to revise, in its own workspace.
  defp current_fact(workspace_id) do
    content = "Hooikamer garantie #{System.unique_integer([:positive])}"

    create_conn =
      request(:post, "/api/memory", %{
        "workspace" => workspace_id,
        "content" => content,
        "metadata" => %{"source" => "revision-test"}
      })

    assert create_conn.status == 201
    {:ok, %{key: token}} = mint_reviewer()

    list_conn = request(:get, "/api/memory-core/claims?workspace=#{workspace_id}")
    {:ok, %{"claims" => [claim]}} = Jason.decode(list_conn.resp_body)

    promote_conn =
      conn(:post, "/api/memory-core/claims/#{claim["id"]}/promote",
        Jason.encode!(%{
          "workspace" => workspace_id,
          "fact_text" => "Geaccepteerd #{content}"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-key", token)
      |> Router.call(@opts)

    assert promote_conn.status == 200
    {:ok, %{"fact" => fact}} = Jason.decode(promote_conn.resp_body)
    {fact, token}
  end

  defp mint_reviewer do
    {:ok, _} =
      OptimalEngine.Identity.Principal.upsert(%{
        id: "user:revision-tester",
        kind: :user,
        display_name: "revision-tester"
      })

    OptimalEngine.Auth.ApiKey.mint(%{
      tenant_id: "default",
      name: "revision-test",
      principal_id: "user:revision-tester"
    })
  end

  describe "PATCH /api/memory-core/facts/:id" do
    test "revises fact_text: old superseded, new current, lineage intact" do
      workspace = "revision-#{System.unique_integer([:positive])}"
      {fact, token} = current_fact(workspace)

      patch_conn =
        conn(:patch, "/api/memory-core/facts/#{fact["id"]}?workspace=#{workspace}",
          Jason.encode!(%{
            "fact_text" => "Hooikamer avondgarantie is 850 euro",
            "reason" => "Nikki correctie 21-09",
            "actor_id" => "nikki"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", token)
        |> Router.call(@opts)

      assert patch_conn.status == 200
      {:ok, body} = Jason.decode(patch_conn.resp_body)
      assert body["fact"]["fact_text"] == "Hooikamer avondgarantie is 850 euro"
      assert body["fact"]["lifecycle_state"] == "accepted"
      assert body["fact"]["verification_status"] == "reviewed"
      assert body["fact"]["supersedes"] == [fact["id"]]
      assert body["old_fact"]["id"] == fact["id"]
      assert body["old_fact"]["superseded_by"] == body["fact"]["id"]

      # GET current_only: exactly one version, the NEW text.
      get_conn =
        request(:get, "/api/memory-core/facts?workspace=#{workspace}&current_only=true")

      {:ok, get_body} = Jason.decode(get_conn.resp_body)
      texts = Enum.map(get_body["facts"], & &1["fact_text"])
      assert get_body["count"] == 1
      assert "Hooikamer avondgarantie is 850 euro" in texts
      refute fact["fact_text"] in texts

      # GET without current_only: history stayed readable.
      all_conn = request(:get, "/api/memory-core/facts?workspace=#{workspace}")
      {:ok, all_body} = Jason.decode(all_conn.resp_body)
      assert all_body["count"] == 2
      old = Enum.find(all_body["facts"], &(&1["id"] == fact["id"]))
      assert old["lifecycle_state"] == "superseded"
      assert old["fact_text"] == fact["fact_text"]
    end

    test "404 on unknown fact" do
      conn =
        request(:patch, "/api/memory-core/facts/fact_bestaatniet?workspace=ws",
          %{fact_text: "x"}
        )

      assert conn.status == 404
    end

    test "400 on empty body and blank fact_text" do
      workspace = "revision-empty-#{System.unique_integer([:positive])}"
      {fact, token} = current_fact(workspace)

      empty =
        conn(:patch, "/api/memory-core/facts/#{fact["id"]}?workspace=#{workspace}", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", token)
        |> Router.call(@opts)

      assert empty.status == 400

      blank =
        conn(:patch, "/api/memory-core/facts/#{fact["id"]}?workspace=#{workspace}",
          Jason.encode!(%{fact_text: "   "})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", token)
        |> Router.call(@opts)

      assert blank.status == 400
    end

    test "409 revising an already-superseded fact" do
      workspace = "revision-sup-#{System.unique_integer([:positive])}"
      {fact, token} = current_fact(workspace)

      first =
        conn(:patch, "/api/memory-core/facts/#{fact["id"]}?workspace=#{workspace}",
          Jason.encode!(%{fact_text: "eerste revisie"})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", token)
        |> Router.call(@opts)

      assert first.status == 200

      second =
        conn(:patch, "/api/memory-core/facts/#{fact["id"]}?workspace=#{workspace}",
          Jason.encode!(%{fact_text: "tweede revisie op oud feit"})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", token)
        |> Router.call(@opts)

      assert second.status == 409
      {:ok, body} = Jason.decode(second.resp_body)
      assert body["error"] =~ "superseded"
    end
  end
end
