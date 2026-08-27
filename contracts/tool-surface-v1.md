# Tool surface, v1 (design contract -- nothing implemented)

Source of truth for the envelope shape: `session-v1.schema.json`.
Failure vocabulary: `failure-codes.md`.

## Allowed actions

| Action             | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `status`           | Read-only: session health, operator lifecycle, state version.       |
| `operator.spawn`   | Spawn ONE configured operator (`op-grok-01` or `op-fred-01`). Refused while Gate-0 is unlifted (`E_GATE0_HELD`). |
| `operator.despawn` | Remove the operator pawn this session spawned, by opaque handle.    |
| `operator.stop`    | Halt all motion/intent for the handle; safe idle.                   |
| `move.bounded`     | Move the handle's pawn toward a clamped world target.               |
| `look.bounded`     | Aim the handle's pawn within clamped yaw/pitch.                     |
| `memory.list`      | List memory keys for the handle's operator store.                   |
| `memory.get`       | Read one bounded memory value.                                      |
| `memory.upsert`    | Write one bounded memory value (host-side store only).              |
| `memory.delete`    | Delete one memory key.                                              |

## Excluded by contract (not a temporary gap -- a bar)

- Arbitrary console commands.
- Arbitrary C# execution.
- Caller-supplied file paths of any kind.
- Scene mutation, scene save, prefab or asset writes.
- Targeting, following, damaging, or reading any human player's pawn.
- Driving the principal pawn or any pawn the session did not spawn.
- Rank or permission changes to any human account.
- Writes to DXRP game persistence or any store outside `intellibot/v1/`.
- Network, filesystem, or process access beyond the loopback game link.

## Standing bars carried into every action

1. ORD 2001.1 -- spawned-pawns-only, by handle; never the principal, never a human.
2. ORD 2001.2 -- admin surface only; never target a human pawn; never write persistent data.
3. ORD 2001.3 -- play-only; never a shipped path.
4. Gate-0 (boards 2003/2005) -- `operator.spawn` refuses in any Host Play until persistence containment passes.
