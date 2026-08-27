# Store layout, v1

```
store/v1/
  SCHEMA.md                      # this file
  operators/
    <operator-id>/               # op-grok-01, op-fred-01
      manifest.json              # store bookkeeping: schemaVersion, operatorId,
                                 #   storeVersion, createdUtc, checksumAlgo,
                                 #   lastKnownGood -- which MUST attest at least
                                 #   profile.json, state.json and
                                 #   summary-current.json (FIX2 F1); each entry
                                 #   is { sha256, bytes, updatedUtc }
      profile.json               # identity mirror of the operator config; no secrets
      state.json                 # lifecycle + lastSessionId + stateVersion;
                                 #   safe defaults when absent
      summary-current.json       # rolling summary of episodes; empty-safe
      episodes/                  # bounded episode files, one JSON per episode
                                 #   named <utc-compact>-<seq>.json
```

## Episode document shape (v1)

```json
{
  "schemaVersion": 1,
  "operatorId": "op-grok-01",
  "sessionId": "...",
  "startedUtc": "...",
  "endedUtc": "...",
  "outcome": "completed | stopped | failed",
  "notes": "bounded free text, <= 16384 bytes total document"
}
```

## Invariants

- Every document carries `schemaVersion`. Future versions freeze the store
  read-only (`E_SCHEMA_FUTURE`).
- Writes are host-only, checksummed into `manifest.json`, and bounded by the
  limits in `config/intellibot.local.json`.
- `manifest.json` must attest the three required documents; an unattested
  required document freezes the store rather than passing verification
  vacuously (FIX2 F1).
- Absent OPTIONAL content reads as empty-safe defaults; absence never blocks
  a safe spawn or stop. **This is not a licence for a missing required
  document (corrected, FIX2-verify).** `manifest.json`, `profile.json`,
  `state.json` and `summary-current.json` are structural: the integrity
  sweep freezes `E_STORE_CORRUPT` when one is absent or unparseable, and
  since FIX2 the manifest must also ATTEST the latter three. Empty-safe
  means an EMPTY document (no episodes, a null `lastOutcome`, a zero
  `episodeCount`) is a legal, non-blocking state -- it does not mean a
  deleted file is tolerated. The two rules read as contradictory before
  this correction; the freeze is the behaviour, and it is deliberate,
  because a required document that vanished cannot be distinguished from
  one an attacker removed.
- Nothing in this store references a human player, a real SteamID of a human,
  a secret, or a DXRP persistence record.

## Write discipline (increment 2; amended by FIX1 and FIX1-verify)

True multi-file atomicity does not exist on this filesystem. The store's
consistency model is therefore stated exactly:

- **Authoritative state is what `manifest.json` attests.** Every mutation
  is ONE staged transaction: all its documents are serialized, staged to
  `<doc>.json.new`, and verified (re-hash, re-parse) BEFORE any commit;
  the manifest is computed from the staged bytes and committed LAST, as
  the commit point (the manifest never tracks itself).
- **A manifest that attests NOTHING freezes the store (FIX2 F1).**
  `lastKnownGood` MUST carry an entry for `profile.json`, `state.json` and
  `summary-current.json`, each a `{ sha256, bytes, updatedUtc }` object
  whose `sha256` is 64 upper-case hex characters. Null, absent, or
  incomplete tracking is NOT read as "an empty set of tracked documents";
  it is a store with no recovery anchor and it refuses `E_STORE_CORRUPT`
  before any healing decision is taken from it. This is what makes
  generation zero crash-recoverable: because the shipped manifest already
  attests the seed documents, a hard crash between the state commit and
  the manifest commit leaves a document that MISMATCHES the manifest while
  its `.lkg` MATCHES it -- the ordinary rollback case -- instead of an
  untracked document that every verification loop skips. Episodes are
  deliberately not part of the baseline: they accrue over time, and an
  episode absent from the manifest is handled as an orphan.
- **Commits are atomic per document.** An existing document is committed
  with a single atomic replace that installs the new bytes and moves the
  previous bytes to `<doc>.json.lkg` (one generation) in one operation --
  there is no delete-then-move window. A brand-new document (a new
  episode) is committed with a single move.
- **In-process failure rolls back.** A fault during staging or commit --
  post-commit verification included, which runs inside the rollback
  envelope -- restores the manifest-attested state before the tool
  returns: committed documents are reverted in reverse order (from their
  `.lkg`, or removed if new), and staging residue is cleared.
- **A rollback that did not fully restore says so (FIX2 F2).** The
  rollback no longer ASSERTS success. After reverting, the store is
  re-read against `manifest.json`; if any restoration threw, or any
  tracked document still does not match what the manifest attests, the
  tool reports `E_STORE_CORRUPT` naming the failed leaves instead of
  `E_INTERNAL`, because authoritative state may have changed and the store
  is not known-good. Only a rollback that verifiably restored the
  manifest-attested state reports `E_INTERNAL` / "rolled back". Staging
  cleanup that fails is reported but does NOT disqualify the claim: a
  leftover `.new` never became authoritative and the next sweep removes it.
- **Crash residue self-heals**, in this order, before any operation: a
  manifest lost inside the replace window (absent on disk, valid staged
  copy present) is forward-completed from that copy; `.new` staging FILES
  are removed; an episode absent from the manifest is QUARANTINED
  (renamed `<name>.json.orphan`, never deleted -- an interrupted append's
  episode is real data, and a manifest last-known-good restore must not
  destroy the newer generation); a tracked document that mismatches the
  manifest while its `.lkg` matches it is rolled back from `.lkg`.
- **The manifest is the root of trust** and is never auto-healed beyond
  the forward-completion above. **That forward-completion is now VERIFIED,
  not merely parsed (FIX2-verify).** A staged manifest is promoted only
  when it carries a valid required baseline AND every one of its
  attestations matches the bytes on disk. This turns the invariant this
  paragraph used to assert -- "a staged manifest can only attest documents
  that were already committed before it" -- from a comment into a checked
  precondition, and it closes a case that needed no attacker at all: the
  rollback path tolerates a failed staging cleanup on the ground that the
  next sweep removes the leftover `.new`, which holds only while
  `manifest.json` still exists. If the manifest were later lost, the
  earlier parse-only promotion would have installed a REVERTED
  generation's manifest as the root of trust, after which the `.lkg`
  rollback step would overwrite live documents to "restore" it --
  destroying a committed generation. A staged manifest that does not match
  disk now freezes `E_STORE_CORRUPT` instead. Forging one that DOES match
  disk still requires write access inside the store, the prerequisite the
  topology guard and the single-writer model already treat as outside the
  threat model; orphan episodes remain quarantined and never deleted.
- **Foreign topology freezes (FIX1-verify F1/F2).** Any reparse point
  (junction/symlink) or foreign subdirectory anywhere inside the operator
  store freezes it `E_STORE_CORRUPT` before any enumerate/delete/write.
  The guard reads attributes only and never follows a link, so a planted
  junction can redirect neither a write nor a delete outside the store,
  and a foreign directory planted at a commit-target path can never
  receive a mis-moved document. A junction supplied as the store root or
  operator directory is refused `E_NOT_HOST` (a reparse point AT or ABOVE
  the repository root is lawful topology and tolerated).
- **Real corruption still freezes:** a tracked document whose live bytes
  and `.lkg` both mismatch the manifest -> `E_STORE_CORRUPT`; any
  `schemaVersion` newer than the build -> `E_SCHEMA_FUTURE`.

**Single writer (FIX1-verify F2).** These are local single-user tools.
Each mutation holds an exclusive lock (`operators/<id>/.session.lock`,
an OS file handle released on every exit) across its self-healing sweep
and commit; a concurrent invocation is refused, never allowed to race the
sweep. The lock file is operational ephemera, excluded from byte
accounting.

**Byte-limit counting rule (FIX1 F3):** `maxTotalBytesPerOperator` is
judged against the PROJECTED POST-COMMIT size of the operator directory
-- documents, the `.lkg` generations they displace, and the new manifest
-- enforced uniformly by every mutation (create, append, close) and
refused as `E_LIMIT` before any byte lands. `.lkg`, `.new`, and `.orphan`
siblings are bookkeeping, not documents: readers of the store ignore
them, and the byte limit counts them (bytes are bytes); the
`.session.lock` handle is excluded. After a faulted rollback the
directory can transiently sit above the limit until the next mutation
re-measures and re-gates; growth cannot compound.

Episode `<seq>` is defined as 1 + the count of existing episodes carrying
the same `sessionId`; episode files are append-only and never rewritten.
**Append-only is enforced by the store, not by the caller (FIX2 F3):** the
store DERIVES append-only status from the leaf -- any `episodes/*.json`
target -- so a caller that omits the flag, or supplies `false`, still
cannot talk the store into overwriting a committed episode. A caller flag
can only ever tighten the rule for a non-episode leaf, never relax it.

`summary-current.json` (v1, rolling, empty-safe) carries:
`schemaVersion`, `operatorId`, `episodeCount` (total on disk),
`lastSessionId`, `lastOutcome` (outcome of the highest-seq episode of the
closing session, `null` when none), `summary` (bounded text, <= 2048
chars), `updatedUtc`.
