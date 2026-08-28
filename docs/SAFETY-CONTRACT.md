# Safety contract

These bars are law for every runtime act of this bot, in every adapter, in
every host. They are copied machine-readably into each
`config/operators/*.operator.json` and enforced again by the tool surface
(`contracts/tool-surface-v1.md`).

## ORD 2001 -- the three bars (ratified)

1. **Spawned-pawns-only.** The seat drives ONLY pawns it spawned, identified by
   GUID (surfaced as an opaque handle). Never the principal pawn. Never any
   human player.
2. **Admin surface only.** Bot SuperAdmin exists to exercise the admin surface
   -- never to target a human pawn, never to write persistent data.
3. **Play-only.** The instrument never registers in a shipped path.

## Gate-0 -- persistence containment (boards 2003/2005, UNLIFTED)

The moment a bot pawn spawns in a Host Play it can serialize into DXRP
production persistence. Until a containment proof passes:

- `operator.spawn` refuses with `E_GATE0_HELD`;
- every `spawnPermitted` flag in `config/operators/` stays `false`;
- no launch, no Play, no test that spawns a synthetic pawn.

## Editor discipline

- Never save the scene. The principal drives the editor in parallel.
- Scene-level editor writes require the principal's spoken per-act word.

## Repository discipline

- Genesis commit HELD (board 2006) until name, description, and licence are
  ratified by the principal.
- No push, ever, without principal word.
- No merge, tag, reset, clean, stash, checkout, or switch by any seat.
- No file named `BOARD.md` anywhere in this tree, ever. One board, one writer.
- Secrets never enter this tree: name and location only.
