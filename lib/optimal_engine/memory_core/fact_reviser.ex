defmodule OptimalEngine.MemoryCore.FactReviser do
  @moduledoc """
  Revise a persisted Fact: close the old row bitemporally and insert a new
  current version, linked through supersession (metadata + relationship edge
  + derivation ledger), the same lineage `FactPromoter` writes on promotion.

  Why not UPDATE-in-place: a fact row is a statement that was true for a
  period of transaction time. Editing the text in place would silently rewrite
  history the mail-oogst evidence still points at; the GET route's
  `current_only` filter would also keep serving the old text to some callers
  and the new text to others. Supersession keeps both: the old row stays
  readable (lifecycle "superseded", transaction_time_end set), the new row is
  the single current version, and `KnowledgeLifecycle.record_fact_supersession`
  writes the edge and ledger entry for the audit trail.

  Allowed changes: fact_text, subject_anchor, action_class, object_anchor,
  scope, stale_after, metadata (merged), verification_status. The rest of the
  row is carried over unchanged from the old fact (lineage, evidence links,
  confidence scores); confidence/precision are deliberately NOT editable
  here, because they are the extractor's scoring, not a human judgement.
  """

  alias OptimalEngine.MemoryCore.{Fact, ID, KnowledgeLifecycle, Store}

  @editable [:fact_text, :subject_anchor, :action_class, :object_anchor, :scope, :stale_after]
  @verification_statuses ["unverified", "verified", "reviewed", "quarantined"]

  @spec revise(Fact.t(), map(), keyword()) ::
          {:ok, %{old: Fact.t(), new: Fact.t()}} | {:error, term()}
  def revise(%Fact{} = old_fact, changes, opts \\ [])
      when is_map(changes) and is_list(opts) do
    with :ok <- validate(old_fact, changes),
         {:ok, new_fact} <- build_revision(old_fact, changes, opts),
         :ok <- Store.insert_fact(new_fact),
         :ok <-
           KnowledgeLifecycle.record_fact_supersession(new_fact, old_fact,
             reason: Keyword.get(opts, :reason) || "revised",
             actor_id: Keyword.get(opts, :actor_id) || "api"
           ) do
      {:ok, %{old: old_fact, new: new_fact}}
    end
  end

  defp validate(%Fact{} = old_fact, changes) do
    cond do
      Map.get(old_fact, :lifecycle_state) == "superseded" ->
        {:error, :fact_superseded}

      not Enum.any?(@editable, &Map.has_key?(changes, &1)) and
          not Map.has_key?(changes, :metadata) and
          not Map.has_key?(changes, :verification_status) ->
        {:error, :no_changes}

      blank_text?(changes) ->
        {:error, :blank_fact_text}

      invalid_verification_status?(changes) ->
        {:error, :invalid_verification_status}

      true ->
        :ok
    end
  end

  defp blank_text?(changes) do
    case changes do
      %{fact_text: text} when is_binary(text) -> String.trim(text) == ""
      %{fact_text: text} when is_nil(text) -> true
      _ -> false
    end
  end

  defp invalid_verification_status?(changes) do
    case changes do
      %{verification_status: status} when is_binary(status) ->
        status not in @verification_statuses

      %{verification_status: status} when is_nil(status) ->
        true

      _ ->
        false
    end
  end

  defp build_revision(%Fact{} = old, changes, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    metadata =
      (Map.get(old, :metadata) || %{})
      |> Map.merge(stringify_keys(Map.get(changes, :metadata) || %{}))
      |> Map.put("revised_at", now)
      |> Map.put("revision_reason", Keyword.get(opts, :reason) || "revised")
      |> Map.put("supersedes", [Map.get(old, :id)])

    attrs =
      %{
        id: new_id(old, opts),
        tenant_id: Map.get(old, :tenant_id, "default"),
        workspace_id: Map.get(old, :workspace_id, "default"),
        fact_type: Map.get(old, :fact_type, "assertion"),
        accepted_claim_ids: Map.get(old, :accepted_claim_ids) || [],
        supporting_evidence_links: Map.get(old, :supporting_evidence_links) || [],
        contradicting_evidence_links: Map.get(old, :contradicting_evidence_links) || [],
        verifier_id: Keyword.get(opts, :actor_id) || Map.get(old, :verifier_id),
        aggregate_confidence: Map.get(old, :aggregate_confidence, 0.5),
        aggregate_precision: Map.get(old, :aggregate_precision, 0.5),
        raw_component_scores: Map.get(old, :raw_component_scores) || %{},
        access_policy_id: Map.get(old, :access_policy_id),
        security_labels: Map.get(old, :security_labels) || [],
        partition_ids: Map.get(old, :partition_ids) || [],
        lifecycle_state: "accepted",
        contradiction_status: Map.get(old, :contradiction_status),
        event_time: Map.get(old, :event_time),
        valid_time_start: Map.get(old, :valid_time_start),
        valid_time_end: Map.get(old, :valid_time_end),
        transaction_time_start: now,
        verification_time: now,
        stale_after: Map.get(old, :stale_after),
        metadata: metadata,
        supersedes: [Map.get(old, :id)]
      }
      |> carry_over(changes, @editable)
      |> maybe_put_verification(changes)

    {:ok, Fact.new(attrs)}
  end

  defp carry_over(attrs, changes, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case changes do
        %{^key => value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp maybe_put_verification(attrs, changes) do
    case changes do
      %{verification_status: status} -> Map.put(attrs, :verification_status, status)
      _ -> Map.put(attrs, :verification_status, "reviewed")
    end
  end

  defp new_id(_old, opts) do
    case Keyword.get(opts, :fact_id) do
      nil -> ID.random_id("fact")
      id when is_binary(id) -> id
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end
end
