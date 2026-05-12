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

Use one section per MIU. Do not dispatch abstract outcome bullets.

### MIU <n> - <Name>

- Runtime path:
- Current code paths:
- Current risky code/API shape:
- Target code/API shape:
- Data lifetime and scope:
- Technology or concurrency constraint:
- Decision and alternatives rejected:
- Exact tests:
- Validation command:

If an issue lacks this detail, mark `needs-code-level-miu` in Linear and stop
before broad codebase rediscovery.

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
