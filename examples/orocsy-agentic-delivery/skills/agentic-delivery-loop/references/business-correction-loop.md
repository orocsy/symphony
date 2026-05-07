# Business Correction Loop

This is the agent's self-logic pass. Run it before coding, after coding, and
when a review comment feels "small but security/business-adjacent."

## Boundary Discovery

Do not assume every project has tenants, bookings, customers, or payments.
Before implementation, discover the project's real boundaries from schemas,
routes, roles, docs, and current code.

Use this generic inventory:

| Boundary type | Examples | Required decision |
| --- | --- | --- |
| Ownership | tenant, org, workspace, account, project, customer | Which id scopes reads and writes? |
| Actor | user, admin, staff, customer, service account, webhook | Who can call this and who cannot? |
| Durable data | database row, object, ledger entry, generated artifact | What is persisted and how long? |
| Ephemeral data | token, OTP, cache entry, browser state, queue message | What expires or is process/browser-local? |
| Money/value | payment, refund, credit, quota, subscription, entitlement | What must be transactionally correct? |
| Time/concurrency | booking, inventory, queue, scheduler, lock, retry | What can race and what arbitrates? |
| External provider | email, SMS, Stripe, storage, AI, analytics | What can be exhausted, replayed, or spoofed? |
| User-visible truth | UI action, status, receipt, notification, report | What must the user see or not infer? |

Mark missing boundaries as `N/A` with a reason. Add project-specific boundaries
that are not listed.

## Correction Questions

| Domain | Ask |
| --- | --- |
| Multi-tenancy | Does every read/write include tenant scope? Does the mutation itself carry the tenant predicate? |
| Customer identity | Could one verified contact match multiple customers? Is this a `findMany` case rather than `findFirst`? |
| Legacy data | Does the new canonical field have a backfill? If not, is there a safe legacy fallback? |
| Auth/session | Is token fallback order correct? Are cookies set and cleared with matching attributes? |
| OTP/magic links | Are attempts atomic? Is TTL preserved? Are responses enumeration-safe in body and timing? |
| External providers | Could forged headers, IP rotation, or high concurrency exhaust Twilio/email/Redis/DB? |
| Booking consistency | Does the operation use a distributed lock plus transactional revalidation? |
| Storage | Are object storage and DB writes compensated if one side fails? |
| Payments/money | Is the financial outcome computed inside the authoritative transaction? |
| Browser state | Is any `blob:`, `File`, localStorage, or client-only state being persisted or trusted? |
| UI action state | Does the backend derive critical action availability, or is the frontend guessing? |

These questions are examples. For a new project, translate them to the
equivalent ownership, actor, money/value, time/concurrency, storage, provider,
and user-visible truth boundaries.

## Reusable Patterns

### Multiple Matching Customers

If a verified contact can map to more than one durable customer row, model it as
many:

```ts
const customers = await prisma.customer.findMany({
  where: {
    tenantId,
    OR: [{ emailNormalized }, { phoneE164 }, { phoneHash }],
  },
  select: { id: true },
});
```

Then fetch bookings across the customer ids with tenant scope. Do not bind the
session or booking list to the first row unless the business invariant says one
row is guaranteed.

### Token And Session Fallback

When a stale email manage token is present but the customer also has a valid
session cookie, the session should still be considered if token validation
fails safely:

```ts
const principal =
  (await tryManageToken(token)) ??
  (await tryCustomerSession(customerSessionToken));
```

Do not throw before checking the fallback path unless the failure itself proves
an abuse case that should end the request.

### OTP Exhaustion

Rate limit at more than one layer:

- Edge/LB/WAF: coarse IP and request volume.
- API: normalized contact, tenant, route, and principal-level limits.
- Redis: atomic counters and TTL preservation.
- Provider: Twilio/email quotas and alerting.

Header-based discrimination is only a signal. Do not trust spoofable headers
unless they come from a trusted load balancer chain.

## Correction Output

Every correction pass should produce one of:

- `safe`: invariant is preserved and test names prove it.
- `needs-fix`: code must change before continuing.
- `needs-design`: business rule is ambiguous and should not be guessed.
- `out-of-scope`: record why and where it belongs.
