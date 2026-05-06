# MIU Execution Document

## Context

- Feature:
- Branch:
- PR:
- Linear:
- Design source:
- Business invariants:

## Business Boundary Inventory

Fill before implementation. Use `N/A` with a reason when a boundary does not
exist in this project.

| Boundary type | Current code / data | Decision |
| --- | --- | --- |
| Ownership |  |  |
| Actor |  |  |
| Durable data |  |  |
| Ephemeral data |  |  |
| Money/value |  |  |
| Time/concurrency |  |  |
| Storage/media |  |  |
| External provider |  |  |
| User-visible truth |  |  |

## MIU 1 - <Name>

One independently reviewable behavior change:

### Runtime Problem

Current risky code or API shape:

```ts
// real code shape here
```

### Data Shape

```ts
type RelevantShape = {
  // real fields here
};
```

Value lifetime and ownership:

| Value | Example | Lifetime | Scope |
| --- | --- | --- | --- |

### Technology Constraint

### Design / Flow

For UI changes, name the design source and browser states. For boundary-crossing
changes, include a Mermaid sequence or state diagram.

### Best-Practice Fix

Target code shape:

```ts
// core target code here
```

### Alternatives Rejected

- Alternative:
  Reason rejected:

### Tests First

- <test>

### Implementation Notes

Explain core lines and decisions. Keep verbose thought process out of
production code comments.

### Validation

```bash
<command>
```

Result:

### Handoff

- Commit:
- Files:
- Blockers:
- Next MIU:
