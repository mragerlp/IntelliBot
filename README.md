# IntelliBot (working name -- UNRATIFIED)

A persistent, MCP-controlled AI operator framework for s&box. CAVELUX product.

> The product name, description, and licence posture above are **unratified**.
> They do not enter permanent history until the principal ratifies them and
> speaks the genesis word (board 2006). This file may be edited freely before
> genesis.

## What this tree is

This repository is the product home for the IntelliBot control plane and its
local store. It is configuration and structure only at this stage. No product
code, no `.sbproj`, no licence file exists yet -- each is held on its own word.

## Layout

- `TO FABLE.txt` -- design intake for this tree (INTELLIBOT-1 architecture packet).
- `branding/` -- brand assets dropped by the principal. Provenance record
  required before any asset enters permanent history.
- `config/` -- local control-plane configuration and operator identities.
- `contracts/` -- the v1 session envelope, tool surface, and failure codes.
- `docs/` -- safety contract and persistence rules.
- `store/v1/` -- the bot's local store, initialized empty-safe. Layout in
  `store/v1/SCHEMA.md`. The eventual game-side runtime store mirrors this
  layout under s&box `FileSystem.Data` (`intellibot/v1/...`); this in-tree
  copy is the control-plane-local store and seed template.
- `tools/` -- file-level control-plane tools (increment 2): envelope
  validator with schema drift sensor, session lifecycle scripts
  (create/append/close, store-contained), operator loader enforcing
  `spawnPermitted=false` under Gate-0. Docs in
  `docs/CONTROL-PLANE-TOOLS.md`.
- `test/` -- the file-level dry-run harness and its fixtures (increment 2;
  the dispatch of 2026-08-22 named this location, superseding the earlier
  "reserved; empty" state). `test/scratch/` and `test/results/` are
  harness litter, gitignored, never part of genesis.
- `publish/` -- reserved by the principal; empty.

## Standing holds

1. **Genesis commit** — released by principal word 2026-08-27 (Cursor/GROK-VNG PR lane). Name, description, and licence remain unratified; this file may still be edited.
2. **No push without principal word** — this PR push is that word for the control-plane tree.
3. **No synthetic pawn in any Host Play** until Gate-0 persistence containment
   passes (boards 2003/2005), except editor-local Intellibot seats already ruled under ORD 2001 in the DXRP workbench `_dev` lane.
4. **No `.sbproj`** until the successor ruling.
5. **No file named `BOARD.md`** in this tree, ever.

## Safety contract

The three ORD 2001 bars plus the Gate-0 bar govern every runtime act of this
bot. See `docs/SAFETY-CONTRACT.md`. They are also embedded machine-readably in
`config/operators/*.operator.json`.
