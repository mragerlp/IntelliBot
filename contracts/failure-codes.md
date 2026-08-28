# Failure codes, v1

Every rejection is fail-closed: the action does not run, AUTHORITATIVE state
does not change, and the code below is returned. Unknown failure conditions
map to `E_INTERNAL` and also leave authoritative state unchanged.

REFUSAL IS NOT PHYSICAL INERTNESS (FIX2 F5). "Nothing changed" is a claim
about AUTHORITATIVE state only -- what `manifest.json` attests. The pre-op
self-healing sweep runs BEFORE the check that refuses, so a refusal may
legitimately have deleted `.new` staging residue, quarantined an orphan
episode, or rolled a document back from its `.lkg` first. Any such healing
is reported on the refusal itself, in the same `healed` field successful
results carry. A refusal with a non-empty `healed` list is normal and is
not evidence of a partial write.

ROLLBACK HONESTY (FIX2 F2 -- THIS TEXT MOVED TO MATCH THE CODE). An
in-process commit fault rolls the store back to the manifest-attested
state, and the tool reports `E_INTERNAL` with exit 3: authoritative state
unchanged, truthfully. But a rollback can itself fail -- a restoration can
be denied or the store can still not match the manifest afterwards. That
case is NO LONGER reported as `E_INTERNAL`. The commit re-reads the store
against `manifest.json` after rolling back, and if any restoration failed
or any tracked document still does not match, it returns `E_STORE_CORRUPT`
(exit 3) naming the failed leaves, because the store is not known-good and
authoritative state MAY have changed. Repair by hand from the `.lkg`
generations before the next operation. Previously the throw asserted a
complete rollback unconditionally and every caller mapped it to
`E_INTERNAL`, which claimed "authoritative state unchanged" over a store
that could have a new manifest authoritative above old leaves.

MANIFEST BASELINE (FIX2 F1). `manifest.json` MUST attest `profile.json`,
`state.json`, and `summary-current.json`. A `lastKnownGood` that is null,
absent, or missing any of those three is NOT an empty trust map -- it is a
store with no recovery anchor, and it freezes `E_STORE_CORRUPT` rather than
being accepted as integral. Without this rule an untracked store passed
every verification loop vacuously (zero entries iterated), which let a hard
crash between two per-document commits promote an unattested state
transition and still report the store as integral.

AUTHORITATIVE STATE, stated exactly (FIX1 amendment): for the operator store
it is what `manifest.json` attests -- the manifest is committed last, as the
commit point of every mutation. True multi-file atomicity does not exist on
this filesystem; what is guaranteed instead is that an in-process failure
rolls the store back to the manifest-attested state before the tool returns
(verification runs inside the rollback envelope), and that residue from a
hard crash is reconciled by the next integrity sweep before any operation
proceeds -- a manifest lost mid-replace is forward-completed from its
verified staged copy, staging residue is removed, an orphan episode is
quarantined (never deleted), and a document is rolled back from its
last-known-good generation. Per-document commits use an atomic replace, so
there is no delete-then-move window. See `store/v1/SCHEMA.md`, write
discipline.

TOPOLOGY (FIX1-verify): a reparse point (junction/symlink) or a foreign
subdirectory anywhere inside the operator store freezes it `E_STORE_CORRUPT`
before any enumerate/delete/write; the guard reads attributes only and never
follows a link, so a planted junction can neither redirect a write nor a
delete outside the store.

SINGLE WRITER (FIX1-verify): these are local single-user control-plane
tools, not a concurrent server. Each lifecycle tool holds an exclusive lock
(`operators/<id>/.session.lock`) across its sweep and commit; a second
concurrent invocation is refused (returned today as `E_INTERNAL` -- no v1
code covers a busy store; `E_BUSY` is proposed for v2) rather than allowed to
race the destructive self-healing sweep.

| Code                    | Meaning                                                            |
| ----------------------- | ------------------------------------------------------------------ |
| `E_PROTOCOL_VERSION`    | Envelope `protocolVersion` not implemented by receiver.            |
| `E_MALFORMED`           | Envelope fails schema validation (unknown field, missing field, bounds). |
| `E_DUPLICATE_REQUEST`   | `requestId` already seen this session (replay guard).              |
| `E_STALE_SEQ`           | `seq` is equal to or lower than the last accepted.                 |
| `E_EXPIRED`             | `expiresUtc` has passed.                                           |
| `E_UNKNOWN_SESSION`     | `sessionId` not open on this host.                                 |
| `E_UNKNOWN_HANDLE`      | `botHandle` does not name a pawn this session spawned.             |
| `E_WRONG_STATE_VERSION` | `expectedStateVersion` mismatch; re-read `status` and retry.       |
| `E_ACTION_EXCLUDED`     | Action outside the v1 surface (also covers future-versioned actions). |
| `E_BOUNDS`              | Argument outside its clamp (move target, look angles, key, value size). |
| `E_GATE0_HELD`          | `operator.spawn` refused: Gate-0 persistence containment unlifted. |
| `E_NOT_HOST`            | Receiver is not the session host; writes are host-only.            |
| `E_STORE_CORRUPT`       | Operator store failed checksum or JSON parse beyond what the self-healing sweep may repair; a required document is not attested by `manifest.json` (FIX2 F1); or a commit rollback did not fully restore the manifest-attested state (FIX2 F2). Store is frozen read-only until repaired from last-known-good. |
| `E_SCHEMA_FUTURE`       | Store or config carries a schema version newer than this build.    |
| `E_LIMIT`               | Store limit exceeded (episode count, episode bytes, total bytes).  |
| `E_INTERNAL`            | Anything else; authoritative state unchanged (any crash residue self-heals on the next sweep). A commit fault reports this code ONLY when the rollback fully restored the manifest-attested state; an incomplete rollback reports `E_STORE_CORRUPT` instead (FIX2 F2). |
