# <ISSUE> <Title>

## Owner

<Agent or lane>

## Branch / PR Contract

- Branch:
- Base:
- PR:
- Push behavior:
- Merge behavior:

## Scope

In:

- <item>

Out:

- <item>

## Runtime Problem

<Concrete runtime scenario.>

## Business Boundary Inventory

| Boundary type | Applies? | Decision |
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

## Data Shape

```ts
type RelevantShape = {
  id: string;
};
```

## MIUs

1. <MIU 1 name>
2. <MIU 2 name>
3. <MIU 3 name>

Each MIU must include technical detail: runtime problem, current/target code
shape, data lifetime, framework/database/browser constraint, tradeoffs,
decision rationale, tests, and validation command.

## Required Tests

- <test name or scenario>

## Validation Commands

```bash
<command>
```

## Handoff Required

- Branch and commit.
- Files changed.
- Tests run and result.
- Browser evidence if UI.
- Blockers.
- Next recommended action.
