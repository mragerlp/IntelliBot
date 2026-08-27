# Persistence rules -- the operator store

Grounded in the INTELLIBOT-1 intake (`TO FABLE.txt`, section 7). The store is
the bot's own memory. It is deliberately separate from, and never writes into,
DXRP game persistence.

## Two copies of one layout

- **In-tree (this repo):** `store/v1/` -- the control-plane-local store and the
  seed template. Initialized empty-safe.
- **Runtime (game side, future):** s&box `FileSystem.Data` under the prefix
  `intellibot/v1/` -- written only by the host-side component, only for
  operators it owns.

## Rules

1. **Host-only writes.** Only the session host writes the store. `E_NOT_HOST`
   otherwise.
2. **No caller paths.** Memory keys are validated flat identifiers
   (`^[a-z0-9][a-z0-9._-]{0,127}$`); a caller can never supply a file path.
3. **No secrets, no PII.** Tokens, credentials, real SteamIDs of humans,
   player/customer records -- none of it enters the store.
4. **Versioned.** Every JSON document carries `schemaVersion`. A version newer
   than the running build freezes the store read-only (`E_SCHEMA_FUTURE`).
5. **Bounded.** Limits ride in `config/intellibot.local.json`:
   512 episodes/operator, 16 KiB/episode, 4 MiB/operator, 90-day retention.
   Exceeding a limit fails the write (`E_LIMIT`); it never silently truncates.
6. **Last-known-good.** Each successful write updates `manifest.json` with the
   checksum of the document written. The store freezes read-only
   (`E_STORE_CORRUPT`) until repaired from last-known-good on: a failed
   checksum or parse; a required document absent; `manifest.json` not
   attesting the required baseline, or a commit rollback that did not fully
   restore it (both FIX2 -- see `contracts/failure-codes.md`).
7. **Fail-safe absence.** Missing memory must never prevent a safe spawn or a
   safe stop. Absent OPTIONAL content reads as its empty-safe default.
   **Corrected (FIX2-verify):** this covers EMPTY content -- no episodes, a
   null `lastOutcome` -- not a DELETED required document. `manifest.json`,
   `profile.json`, `state.json` and `summary-current.json` are structural
   and their absence freezes the store per rule 6. `config/intellibot.local.json`
   still carries the older unqualified wording of this rule; that file is
   outside the FIX2 write ceiling and is flagged for the conductor rather
   than edited here.

## Per-operator layout

See `store/v1/SCHEMA.md`.
