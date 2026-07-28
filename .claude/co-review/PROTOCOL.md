# Co-Review Protocol (Claude ↔ other agent)

Both agents honor these conventions so a review relay never deadlocks or both-edits-at-once.

## Turn marker (cooperative lock)
- Doc channels carry `<!-- TURN: claude|codex -->` at the top of REVIEW-CYCLE.md.
- You WRITE (findings / acks / doc edits) only when `TURN == you`. When `TURN == other`, you are READ-ONLY (detect + report).
- After writing, flip the marker to the other agent and COMMIT. Git commit atomically transfers the turn.
- On `git pull` divergence: LAST-WRITER RECONCILES by merge. NEVER force-push a co-review doc.

## Round + finding format (in REVIEW-CYCLE.md)
- `## Round N — <agent> — <iso-ts>` opens a round authored by that agent.
- `### [P1|P2|P3] <code|design>: <title> — locator: <file:line | #anchor>` is one finding.
- `> <agent>-ack: <resolution + pointer>` acknowledges a finding as addressed.
- Untagged prose is tolerated but parsed as one coarse finding — prefer the tagged form.

## Cursors
- Each side tracks what it has already seen in its own `<channel>.cursor.json` (never shared/edited by the other).
- Newness is cursor-gated ONLY (timestamp for PR bots, doc commit SHA for docs). Re-anchored/re-flagged old items are NOT new.
