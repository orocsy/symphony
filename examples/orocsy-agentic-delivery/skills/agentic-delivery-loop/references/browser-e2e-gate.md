# Browser E2E Gate

Use this for any UI-impacting or customer-visible change.

## Gate Order

1. Read design source and current implementation.
2. Write component/API tests for behavior.
3. Start dev server or use existing local server.
4. Exercise the real route in browser.
5. Capture evidence for desktop and mobile.
6. Record product defects separately from harness blockers.

## Browser Truth Checklist

- Page renders without blank screen or hydration error.
- Critical CTA is visible and clickable.
- Form inputs accept realistic data.
- Success, loading, error, empty, and recovery states render.
- Mobile width around 375-390 px has no horizontal overflow.
- Desktop width around 1024-1440 px uses space correctly.
- Customer-visible copy does not mention internal tickets, agents, or workstreams.
- Auth/session flows are tested through the browser boundary, not by reading
  httpOnly cookies in client code.

## Evidence Format

```md
## Browser Evidence

Route:
Viewport:
User path:
Screenshots:
- `path/to/desktop.png`
- `path/to/mobile.png`

Result:
- `passed`
- `failed`
- `blocked`

Blocker, if any:
```

## Harness Failure Rule

Do not call product testing complete when the browser tool failed before
interacting with the page. Record the blocker and either:

- Use the requested in-app browser once it is recoverable.
- Use Playwright as a fallback and capture screenshots.
- Use a visible browser/manual pass and write the exact missing automation gap.

