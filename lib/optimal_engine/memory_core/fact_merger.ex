defmodule OptimalEngine.MemoryCore.FactMerger do
  @moduledoc """
  Merge two or more current Facts of one workspace into ONE new Fact with a
  human-written text.

  Why (Nikki, 23-09): the brain holds many facts that say nearly the same
  thing. Revising them one by one leaves them all standing; the shop needs
  "these three are one".

  The lineage is the one a revision (`FactReviser`) writes, once per old
  fact: the old row is closed (lifecycle "superseded", transaction_time_end
  set, `superseded_by` = the new id, `supersession_reason` in its metadata),
  a "supersedes" relationship edge and a `memory_core.supersede_fact` ledger
  entry record the step. The shell already follows that chain to move the
  shop's confirmations onto the fact that is current now (U9), so a Klopt on
  any of the old facts lands on the merged one without extra work.

  On top of that one `memory_core.merge_facts` ledger entry records the merge
  as a single act: which facts, into which, by whom, and why.

  The new fact:

    * text: the given `fact_text`, never generated;
    * anchors, type, scope, times, access policy, metadata: from the FIRST
      id in the list (the base), the way a revision carries its one old row;
    * lineage: the union of every old fact's claims and evidence links, and
      the union of their security labels and partitions (a merged fact is
      never visible to more people than each of its parts);
    * confidence/precision: the highest of the old facts (a revision carries
      its one old score unchanged; with several there is no "unchanged");
    * verification_status "reviewed": a human wrote this text.

  Refused, with nothing written: fewer than two distinct ids, a blank text, a
  blank reason, an id that is not a fact of this workspace, a fact that is no
  longer current, or facts that differ in tenant or access policy.

  Everything is written in ONE `OptimalEngine.Store.transaction/2`, and every
  close re-checks that the old row is still current, so a merge that races a
  revision of one of its facts rolls back whole instead of half-merging.

  `dry_run: true` runs the same validation and builds the same result, and
  writes nothing. The preview fact has no id: there is no fact to point at.
  """

  alias OptimalEngine.Store, as: EngineStore

  alias OptimalEngine.MemoryCore.{
    DerivationLedgerEntry,
    Fact,
    FactPromoter,
    ID,
    JSON,
    RelationshipEdge,
    ScoringPolicy,
    Store
  }

  # Keys a base fact may carry from its own earlier history; they describe
  # that fact, not the merge, so they do not travel into the new row.
  @history_keys [
    "supersedes",
    "superseded_by",
    "supersession_reason",
    "revised_at",
    "revision_reason"
  ]

  @type result :: %{fact: Fact.t(), old_facts: [Fact.t()], dry_run: boolean()}

  @spec merge(String.t(), [String.t()], String.t() | nil, keyword()) ::
          {:ok, result()} | {:error, term()}
  def merge(workspace_id, fact_ids, fact_text, opts \\ [])
      when is_binary(workspace_id) and is_list(opts) do
    reason = trimmed(Keyword.get(opts, :reason))
    actor_id = Keyword.get(opts, :actor_id) || "api"
    ids = distinct_ids(fact_ids)

    with :ok <- validate_request(ids, fact_text, reason),
         {:ok, old_facts} <- load_current(workspace_id, ids),
         :ok <- same_scope(old_facts) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      if Keyword.get(opts, :dry_run, false) do
        preview = build_fact(old_facts, fact_text, reason, actor_id, nil, now)
        {:ok, %{fact: preview, old_facts: old_facts, dry_run: true}}
      else
        new_fact = build_fact(old_facts, fact_text, reason, actor_id, ID.random_id("fact"), now)

        with {:ok, _} <- write(new_fact, old_facts, reason, actor_id, now),
             # Teruglezen: het bewijs is de rij, niet wat wij dachten te schrijven.
             {:ok, persisted} <- Store.get_fact(workspace_id, new_fact.id) do
          {:ok, %{fact: persisted, old_facts: old_facts, dry_run: false}}
        end
      end
    end
  end

  # -- validation

  defp distinct_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp distinct_ids(_ids), do: []

  defp validate_request(ids, fact_text, reason) do
    cond do
      length(ids) < 2 -> {:error, :too_few_facts}
      not (is_binary(fact_text) and String.trim(fact_text) != "") -> {:error, :blank_fact_text}
      is_nil(reason) -> {:error, :reason_required}
      true -> :ok
    end
  end

  # Current = the same rule the Klopt route (`Store.verify_fact`) applies:
  # open transaction time and not superseded. A retracted fact has a closed
  # transaction time, so it falls out here too.
  defp load_current(workspace_id, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Store.get_fact(workspace_id, id) do
        {:ok, %Fact{} = fact} ->
          if current?(fact) do
            {:cont, {:ok, [fact | acc]}}
          else
            {:halt, {:error, {:fact_not_current, fact}}}
          end

        {:error, :not_found} ->
          {:halt, {:error, {:fact_not_found, id}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp current?(%Fact{} = fact) do
    is_nil(fact.transaction_time_end) and fact.lifecycle_state != "superseded"
  end

  defp same_scope(old_facts) do
    case old_facts |> Enum.map(&{&1.tenant_id, &1.access_policy_id}) |> Enum.uniq() do
      [_one] -> :ok
      _many -> {:error, :scope_mismatch}
    end
  end

  # -- the new fact

  defp build_fact([base | _] = old_facts, fact_text, reason, actor_id, id, now) do
    ids = Enum.map(old_facts, & &1.id)

    metadata =
      (base.metadata || %{})
      |> Map.drop(@history_keys)
      |> Map.put("merged_at", now)
      |> Map.put("merge_reason", reason)
      |> Map.put("merged_from", ids)

    Fact.new(%{
      id: id,
      tenant_id: base.tenant_id,
      workspace_id: base.workspace_id,
      fact_text: fact_text,
      fact_type: base.fact_type,
      subject_anchor: base.subject_anchor,
      action_class: base.action_class,
      object_anchor: base.object_anchor,
      scope: base.scope,
      accepted_claim_ids: union(old_facts, :accepted_claim_ids),
      supporting_evidence_links: union(old_facts, :supporting_evidence_links),
      contradicting_evidence_links: union(old_facts, :contradicting_evidence_links),
      verifier_id: actor_id,
      verification_status: "reviewed",
      aggregate_confidence: old_facts |> Enum.map(& &1.aggregate_confidence) |> Enum.max(),
      aggregate_precision: old_facts |> Enum.map(& &1.aggregate_precision) |> Enum.max(),
      raw_component_scores: base.raw_component_scores,
      access_policy_id: base.access_policy_id,
      security_labels: union(old_facts, :security_labels),
      partition_ids: union(old_facts, :partition_ids),
      lifecycle_state: "accepted",
      contradiction_status: base.contradiction_status,
      event_time: base.event_time,
      valid_time_start: base.valid_time_start,
      valid_time_end: base.valid_time_end,
      transaction_time_start: now,
      verification_time: now,
      stale_after: base.stale_after,
      metadata: metadata,
      supersedes: ids
    })
  end

  defp union(facts, key) do
    facts
    |> Enum.flat_map(&(Map.get(&1, key) || []))
    |> Enum.uniq()
  end

  # -- the write, all or nothing

  defp write(%Fact{} = new_fact, old_facts, reason, actor_id, now) do
    EngineStore.transaction(fn txn ->
      with :ok <- FactPromoter.txn_insert_fact(txn, new_fact),
           :ok <- supersede_all(txn, new_fact, old_facts, reason, actor_id, now),
           :ok <-
             FactPromoter.txn_insert_derivation_entry(
               txn,
               merge_entry(new_fact, old_facts, reason, actor_id, now)
             ) do
        {:ok, new_fact}
      end
    end)
  end

  defp supersede_all(txn, new_fact, old_facts, reason, actor_id, now) do
    Enum.reduce_while(old_facts, :ok, fn old_fact, :ok ->
      case supersede(txn, new_fact, old_fact, reason, actor_id, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Same three writes as `KnowledgeLifecycle.record_fact_supersession/3` (the
  # revision path), but inside the transaction, and the close is conditional.
  defp supersede(txn, new_fact, old_fact, reason, actor_id, now) do
    new_ref = DerivationLedgerEntry.object_ref("fact", new_fact.id)
    old_ref = DerivationLedgerEntry.object_ref("fact", old_fact.id)

    edge =
      RelationshipEdge.between(
        new_fact,
        {"fact", new_fact.id},
        {"fact", old_fact.id},
        "supersedes",
        confidence: new_fact.aggregate_confidence,
        precision_score: new_fact.aggregate_precision,
        evidence_links: [new_ref, old_ref]
      )

    ledger =
      DerivationLedgerEntry.new(
        "memory_core.supersede_fact",
        "fact_supersession",
        [new_ref],
        [old_ref],
        tenant_id: new_fact.tenant_id,
        workspace_id: new_fact.workspace_id,
        evidence_links: [new_ref, old_ref],
        actor_id: actor_id,
        evaluator_id: actor_id,
        scoring_policy_version: ScoringPolicy.version(),
        access_policy_id: new_fact.access_policy_id,
        security_labels: new_fact.security_labels,
        partition_ids: new_fact.partition_ids,
        metadata: %{reason: reason, merged_into: new_fact.id, recorded_at: now}
      )

    with :ok <- close(txn, old_fact, new_fact.id, reason, now),
         :ok <- FactPromoter.txn_insert_relationship_edge(txn, edge) do
      FactPromoter.txn_insert_derivation_entry(txn, ledger)
    end
  end

  # The UPDATE re-checks that the row is still current. Zero rows means a
  # revision, retraction or other merge closed it after we read it: the whole
  # merge rolls back. valid_time_end is left alone: merging changes how the
  # engine records the statement, not when it was true in the world.
  defp close(txn, %Fact{} = old_fact, new_id, reason, now) do
    metadata =
      (old_fact.metadata || %{})
      |> Map.put("superseded_by", new_id)
      |> Map.put("supersession_reason", reason)

    sql = """
    UPDATE facts
    SET lifecycle_state = 'superseded',
        contradiction_status = 'superseded',
        transaction_time_end = ?3,
        metadata = ?4,
        updated_at = datetime('now')
    WHERE workspace_id = ?1 AND id = ?2
      AND transaction_time_end IS NULL AND lifecycle_state <> 'superseded'
    """

    case EngineStore.txn_execute(txn, sql, [
           old_fact.workspace_id,
           old_fact.id,
           now,
           JSON.map(metadata)
         ]) do
      {:ok, 1} -> :ok
      {:ok, _} -> {:error, {:fact_not_current, old_fact}}
      {:error, _} = error -> error
    end
  end

  defp merge_entry(new_fact, old_facts, reason, actor_id, now) do
    old_refs = Enum.map(old_facts, &DerivationLedgerEntry.object_ref("fact", &1.id))
    new_ref = DerivationLedgerEntry.object_ref("fact", new_fact.id)

    DerivationLedgerEntry.new(
      "memory_core.merge_facts",
      "fact_merge",
      old_refs,
      [new_ref],
      tenant_id: new_fact.tenant_id,
      workspace_id: new_fact.workspace_id,
      evidence_links: [new_ref | old_refs],
      actor_id: actor_id,
      evaluator_id: actor_id,
      scoring_policy_version: ScoringPolicy.version(),
      access_policy_id: new_fact.access_policy_id,
      security_labels: new_fact.security_labels,
      partition_ids: new_fact.partition_ids,
      metadata: %{
        reason: reason,
        merged_from: Enum.map(old_facts, & &1.id),
        merged_into: new_fact.id,
        recorded_at: now
      }
    )
  end

  defp trimmed(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_reason), do: nil
end
