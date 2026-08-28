# Control-plane tools (increment 2)

File-level tooling for the IntelliBot control plane. Windows PowerShell
5.1, zero external dependencies, pure ASCII sources. Nothing here
launches a runtime: no s&box, no editor, no Host Play, no pawn, no
network. Gate-0 (boards 2003/2005) stands unlifted and these tools both
respect and enforce it.

## Inventory

| Path | Class | Write surface |
| --- | --- | --- |
| `tools/validate-session.ps1` | validator | none (read-only) |
| `tools/session-create.ps1` | lifecycle | resolved store root only |
| `tools/session-append.ps1` | lifecycle | resolved store root only |
| `tools/session-close.ps1` | lifecycle | resolved store root only |
| `tools/load-operators.ps1` | loader | none (read-only) |
| `tools/lib/intellibot-common.ps1` | shared lib | none (functions only) |
| `tools/lib/intellibot-store.ps1` | shared lib | store write dance lives here |
| `tools/lib/intellibot-operators.ps1` | shared lib | none (judgment only) |
| `test/run-dryrun.ps1` | harness | `test/scratch/`, `test/results/` |
| `test/run-fix2-oldfail.ps1` | differential harness | `test/scratch/`, `test/results/` |

Every tool emits exactly one JSON document on stdout and meaningful exit
codes: `0` success, `2` refused (the JSON carries a failure code from
`contracts/failure-codes.md`), `3` tool fault. The loader adds exit `1`
for the Gate-0 tamper refusal so that reads differently from an ordinary
refusal. Refusals are fail-closed: AUTHORITATIVE state -- what
`manifest.json` attests -- has not changed when one returns.

**A refusal is not necessarily physically inert (FIX2 F5).** The pre-op
self-healing sweep runs BEFORE the check that refuses, so a refusal may
legitimately have removed `.new` staging residue, quarantined an orphan
episode, or rolled a document back from its `.lkg` first. That healing is
now reported ON the refusal, in the same `healed` field successful results
carry, instead of being invisible. The earlier blanket wording ("nothing
has changed") predated the FIX1 redefinition from physical immutability to
manifest authority and was left behind by it; this is the correction.

## validate-session.ps1

Judges envelope JSON files against `contracts/session-v1.schema.json`.

- **Drift sensor.** The checks are hand-mirrored from one exact schema
  revision, whose pin (`4248 B / 0D1CE3DC5708B740F1D9C8833369A42B091BCDC1DEC473E9508D56D5F654DAB6`)
  is embedded in the tool. Every run re-hashes the live schema; a
  mismatch refuses to judge (exit 3). **When the schema is revised, the
  validator must be re-authored against it and its embedded pin updated
  in the same change.**
- **Code mapping** (the schema and the failure vocabulary overlap; this
  is the documented resolution):
  - structural faults (unknown/missing field -- case-sensitively judged,
    wrong type, top level not an object, unparseable JSON, or a
    date-time outside the RFC 3339 lexical space -- an offset, `Z`/`z`
    or `+/-hh:mm`, is REQUIRED; offset-free local times are refused, not
    guessed at -- FIX1 F4) -> `E_MALFORMED`
  - `protocolVersion` an integer but not `1` -> `E_PROTOCOL_VERSION`
  - `action` a string outside the v1 enum -> `E_ACTION_EXCLUDED`
  - args clamp violations (`moveTarget`, `lookYawPitch`, `memoryKey`
    pattern, `memoryValue` size, `operatorId` enum) -> `E_BOUNDS`
  - `expiresUtc` parseable but past -> `E_EXPIRED` (a static judgment
    against now-UTC; the host re-judges at receipt time). DOCUMENTED
    DIVERGENCE (FIX1-verify F4, fail-closed): the accepted subset excludes
    three RFC-3339-legal shapes the underlying parser cannot represent --
    the leap second (`23:59:60`), UTC offsets beyond `+/-14:00`, and year
    `0000` -- all refused `E_MALFORMED`. Rejecting a legal value is the
    safe direction for an expiry gate.
  - primary-code precedence when several apply:
    `E_MALFORMED > E_PROTOCOL_VERSION > E_ACTION_EXCLUDED > E_BOUNDS > E_EXPIRED`
- **Out of scope at file level** (host-state codes, enforced at runtime
  by the session host, never judgeable from a file): `E_DUPLICATE_REQUEST`,
  `E_STALE_SEQ`, `E_UNKNOWN_SESSION`, `E_WRONG_STATE_VERSION`,
  `E_NOT_HOST`, `E_GATE0_HELD`, `E_STORE_CORRUPT`, `E_SCHEMA_FUTURE`,
  `E_LIMIT`. Every result object says so.
- An advisory layer notes schema-legal but operationally inert pairings
  (an args field the action does not read, or an absent field the action
  needs). Advisories never affect the verdict.
- `maxLength`/length checks count UTF-16 code units (PowerShell string
  length); identical to code points for the ASCII content this tree
  authors.

## Session lifecycle: create / append / close

Control-plane session bookkeeping over the local store. **These open,
append to, and close session RECORDS. They spawn nothing and cannot:**
no runtime exists in this tree and `operator.spawn` stays barred by
Gate-0.

- **Containment (FIX1 F1 + FIX1-verify).** Default store root is
  `store/v1`. `-StoreRoot` exists solely so the dry-run harness can
  exercise the machinery against a scratch copy under `test/scratch/`;
  any root outside this repository tree, or whose chain crosses a reparse
  point (junction/symlink) below the repository root, refuses
  `E_NOT_HOST`. Beyond that, `Test-IbStoreShape` freezes `E_STORE_CORRUPT`
  on ANY reparse point or foreign subdirectory anywhere inside the
  operator store -- including `episodes\`, document leaves, and
  commit-target paths -- reading attributes only and never following a
  link, so a planted junction cannot redirect a write or a delete outside
  the store. Production posture is `store/v1` only. `-ConfigPath` (harness
  only) is containment-guarded the same way.
- **Roster gate.** Every lifecycle call resolves its operator through the
  full fail-closed roster judgment (see loader below), so a tampered
  `spawnPermitted=true` anywhere blocks session work too.
- **Single writer (FIX1-verify F2).** Each mutation holds an exclusive
  lock (`operators/<id>/.session.lock`) across its sweep and commit,
  released on every exit; a concurrent invocation is refused
  (`E_INTERNAL`, `E_BUSY` proposed for v2), never allowed to race the
  self-healing sweep.
- **Required manifest baseline (FIX2 F1).** The sweep refuses
  `E_STORE_CORRUPT` when `manifest.json` does not attest `profile.json`,
  `state.json` and `summary-current.json` -- checked BEFORE any healing
  decision is taken from the tracked map, so an unattested manifest can
  never drive a quarantine or a rollback. A null/absent/incomplete
  `lastKnownGood` is a store with no recovery anchor, not an empty trust
  map. This is what makes the first generation crash-recoverable: the
  shipped manifests attest their seed documents, so a crash between the
  state commit and the manifest commit presents as an ordinary
  mismatch-with-matching-`.lkg` rollback rather than as an untracked
  document every verification loop skips.
- **Integrity sweep with self-healing (FIX1 F2 + FIX1-verify).** Before
  any operation, after the shape guard: a manifest lost mid-replace is
  forward-completed from its staged copy **only when that copy carries a
  valid baseline AND every attestation in it matches the bytes on disk
  (FIX2-verify)** -- a staged manifest that does not match is stale or
  planted, not a lost commit, and freezes `E_STORE_CORRUPT`; `.new` staging files
  are removed; orphan episodes (absent from the manifest) are QUARANTINED
  (renamed `.orphan`, never deleted); a tracked document mismatching the
  manifest whose `.lkg` matches it is rolled back from `.lkg`. Healing
  actions are reported in the tool's `healed` output field. What survives
  healing freezes the store: unparseable documents or post-heal checksum
  mismatches -> `E_STORE_CORRUPT`; `schemaVersion > 1` ->
  `E_SCHEMA_FUTURE`. The manifest is the root of trust.
- **Staged transaction (FIX1 F2 + FIX1-verify).** Every mutation goes
  through `Invoke-IbStoreCommit`: ALL documents staged to `.new` and
  verified before any commit; existing documents committed with an atomic
  replace (new bytes in, previous bytes to `.lkg`, one operation -- no
  delete-then-move window), a new episode with a single move; the manifest
  committed LAST as the commit point; post-commit verification runs INSIDE
  the rollback envelope, so any fault -- verification included -- triggers
  a reverse-order rollback to the manifest-attested state. Authoritative
  state is what the manifest attests -- see `contracts/failure-codes.md`.
- **Honest rollback outcome (FIX2 F2).** The rollback does not assert its
  own success. After reverting, the store is re-read against the manifest.
  A rollback that verifiably restored the manifest-attested state reports
  `E_INTERNAL` (exit 3) with "rolled back" -- authoritative state
  unchanged, truthfully. A rollback where any restoration threw, or where
  a tracked document still does not match the manifest, reports
  `E_STORE_CORRUPT` (exit 3) naming the failed leaves: the store is not
  known-good, authoritative state MAY have changed, and it must be
  repaired by hand from the `.lkg` generations before the next operation.
  Staging-cleanup failure is reported but does not disqualify the claim --
  a leftover `.new` never became authoritative.
- **Limits (FIX1 F3)** ride in `config/intellibot.local.json` and refuse
  with `E_LIMIT`; nothing silently truncates. The total-byte limit is
  judged against the PROJECTED POST-COMMIT footprint (documents +
  displaced `.lkg` generations + the new manifest) and is enforced
  uniformly by create, append, and close. Episode documents are
  append-only and named `episodes/<utc-compact>-<seq>.json` where
  `<seq>` = 1 + the count of existing episodes carrying the same
  sessionId; append additionally gates per-episode bytes and episode
  count. **Append-only is DERIVED by the store from the leaf (FIX2 F3),**
  not trusted from caller metadata: any `episodes/*.json` target is
  append-only regardless of what the caller passes, so a future caller
  that omits or negates the flag cannot overwrite a committed episode.
- **Session-state refusal gap (declared).** "A session is already open"
  has no code in the v1 vocabulary. Per the catch-all clause in
  `contracts/failure-codes.md` the tools return `E_INTERNAL` with a
  message naming the condition. **Proposed for the next contract
  revision: `E_SESSION_STATE`** -- the state machine refusal (open when
  open, close/append when not open with a matching id maps today to
  `E_UNKNOWN_SESSION`, which the vocabulary does cover).

## load-operators.ps1

Loads `config/intellibot.local.json` and judges every operator config it
names, whole-roster fail-closed: the first refused file refuses the load.

- **The enforced law:** while Gate-0 stands unlifted, `spawnPermitted`
  MUST be `false`. A config carrying `true` is tamper evidence:
  `E_GATE0_HELD`, exit 1, roster refused.
- Also judged: strict parse, `schemaVersion` gate, required fields,
  operatorId and fake-SteamId patterns (non-real `7650...` range only),
  and the presence of all four standing bar tokens (`ORD 2001.1`,
  `ORD 2001.2`, `ORD 2001.3`, `GATE-0`) in `bars[]`.
- `-RepoRoot` points the judgment at a fixture tree (used by the harness
  with `test/fixtures/tamper-repo/`); it defaults to this repository.

## test/run-dryrun.ps1

The file-level dry-run harness. Fresh scratch tree per run
(`test/scratch/run-<utc>/`), results to `test/results/dryrun-<utc>.json`
and `.md`. Both directories are gitignored; nothing under them is ever
part of genesis. **79 checks as of FIX2**, and the breakdown sums
to that total:

| Series | Checks | Covers |
| --- | ---: | --- |
| V (validator) | 21 | `V01`-`V19` envelope verdicts plus `V90` mixed-input exit code and `V91` drift-sensor refusal (exercised against a scratch copy of the tools with a deliberately moved schema copy -- the real schema is never touched); includes the F4 date-time regressions: tz-free, offset-minute, trailing-LF, and the offset/lowercase-z controls |
| S (lifecycle) | 12 | `S01`-`S12` open/append/close, refusals, freezes, containment; `S12` asserts `.new` FILE staging residue self-heals |
| L (loader) | 2 | real roster loads with `spawnPermitted` universally false; tampered `true` refused `E_GATE0_HELD` |
| R (FIX1 / FIX1-verify) | 23 | junction store-root refusal with target byte-identity; foreign-directory freezes with no partial state; episodes-junction write-escape and delete-escape both blocked; foreign-directory-at-commit-target frozen with the manifest never advancing; live mid-commit rollback via a held file handle, with post-rollback usability; manifest forward-recovery; orphan quarantine; reparse-at-lock-path refusal; hidden-orphan quarantine; staged-pin reporting; the single-writer lock; and the exact-limit projected-footprint refusal |
| R (FIX2 / cross-vendor regrade) | 12 | `R15a`-`c` first-generation crash residue between the two per-document commits is recovered from `.lkg` and the orphaned crash session discarded; `R16a`-`b` a null or incomplete manifest baseline freezes instead of becoming an empty trust map; `R17a`-`c` a rollback that did not fully restore reports `E_STORE_CORRUPT`, names the failed leaf, and is independently confirmed by post-rollback verification; `R18a`-`b` the store refuses an episode overwrite even when the caller passes `AppendOnly=$false`, leaving the episode byte-identical; `R19a`-`b` healing performed before an unrelated refusal is reported on that refusal |
| R (FIX2-verify / author's adversarial pass) | 6 | Defects found IN THE FIX2 CURE by four independent read-only refuters run before the return: `R20` a manifest missing an identity field freezes instead of passing the sweep and then faulting every commit at an unguarded read outside the rollback envelope; `R21` a malformed EPISODE manifest entry freezes instead of raising a StrictMode fault mid-sweep; `R22a` an EOL-only checksum mismatch is named as a line-ending difference rather than left indistinguishable from corruption, with `R22b` the control proving real corruption does NOT get that note; `R23a`-`b` a STALE staged manifest is not forward-completed (it freezes) and the committed generation it would have reverted survives |
| A3 (FIX1-AMEND) | 2 | `operators[]` config path escaping the repository refused `E_NOT_HOST`; the seed-identity control itself detects a hidden planted file |
| N (negative control) | 1 | **N01: the seed `store/v1` is fingerprinted whole (hidden files included) before and after the run and must be byte-identical** |
| **Total** | **79** | |

Every R- and A3-series check derives from a reviewer's recorded scratch
positive and is built to fail on the pre-fix code and pass on the fixed
code -- with ONE declared exception, corrected under FIX2 F4: **`R14` is a
consistency check, NOT a fails-on-old regression.** The pre-fix code
re-read the reported pin from disk, which returns the same value on a
healthy filesystem, so `R14` passed on the old code too. No differential
is constructible for that cure (every value the fixed code reports is also
read PRE-commit by the staging readback, so any injected fault breaks the
earlier read first and the transaction never reaches the reporting line).
The claim was narrowed and the check relabelled rather than a synthetic
differential manufactured; its label now says so.

Run it:

    powershell -File test\run-dryrun.ps1

Exit 0 only when every check passes.

## test/run-fix2-oldfail.ps1

The **old-fail half** of the FIX2 regressions. Law 1847 says a regression
that does not FAIL on the old code did not prove its cure, and the
cross-vendor regrade raised that to apply to the tests themselves. Rather
than assert the old-fail half in prose, this harness DEMONSTRATES it: it
reconstructs a pre-FIX2 tree under `test/scratch/oldfail-<utc>/` by
reversing each FIX2 hunk exactly (16 reversals), then runs the
`R15`/`R16`/`R17`/`R18`/`R19` constructions against it and asserts each
produces the DEFECTIVE outcome (14 checks: `OB01`, `O15a`-`c`, `O16`,
`O16b`, `O17a`-`b`, `O18a`-`b`, `O19a`-`c`, `ON01`).

**Scope, stated honestly.** These are not identical constructions
everywhere, and the harness header enumerates each divergence: `O15` and
`O16b` are forced equivalents (with a null baseline there is no
attestation to rewrite or remove); `R17c` has no counterpart because the
mechanism it checks did not exist pre-FIX2, so its old-fail half is
carried by `O17a`/`O17b`; `R14` has none by design; and `R20`-`R22` are
differentials against FIX2-as-first-written, a tree that was never filed,
so they are not mirrored here.

It is **self-verifying**: every reversal asserts its anchor text was
actually found, and `OB01` asserts the expected reversal count. A stale
anchor fails loudly (exit 3) instead of silently producing a half-old tree
-- which is the failure mode that matters, because a reversal harness that
quietly reverses nothing would "prove" old-fail against already-fixed
code. This guard has already earned itself: a later FIX2-verify edit to
the lifecycle catch blocks invalidated an anchor, and the harness refused
to report rather than reconstructing a tree that was only partly old. The
per-check stores are created INSIDE the reconstructed tree,
because the old tools resolve their repo root from their own
`$PSScriptRoot` and would (correctly) refuse `E_NOT_HOST` for a store root
outside it -- a sibling directory would make every check measure
containment instead of the defect under test.

Like the main harness it launches nothing, writes only under
`test/scratch/` and `test/results/`, and proves the seed `store/v1`
byte-identical before and after (`ON01`).

    powershell -File test\run-fix2-oldfail.ps1

Exit 0 only when every old-fail check behaved defectively as expected.

## Known 5.1 discipline notes

- Function returns unroll empty arrays: array-returning helper calls are
  re-wrapped in `@()` at call sites (a fault of exactly this class was
  found and fixed by the increment-2 smoke tests).
- `ConvertFrom-Json` (5.1) throws on duplicate keys, compared
  case-insensitively; the validator treats that parse failure as
  `E_MALFORMED` (fail-closed), while field-name judgment on parsed
  objects is case-sensitive.
- Tool-level refusals never use `Write-Error` (under
  `ErrorActionPreference=Stop` it would throw past the exit); they emit
  the JSON refusal on stdout and exit.
