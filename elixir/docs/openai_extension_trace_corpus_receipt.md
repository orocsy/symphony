# OpenAI Extension Trace Corpus Preservation Receipt

Status: Source protected in place; not a durable or sanitized archive

Recorded: 2026-07-30

Owner role: repository owner / local runtime operator

## Scope

This receipt covers the five retained, rotated Symphony logs used as source
material for future replay-fixture sanitization:

```text
elixir/log/symphony.log.1
elixir/log/symphony.log.2
elixir/log/symphony.log.3
elixir/log/symphony.log.4
elixir/log/symphony.log.5
```

They were copied without content inspection to this Git-ignored snapshot on
the same migration host:

```text
elixir/log/oxe-openai-extension-source-20260730/
```

The snapshot directory is owner-only (`0700`); copied files are read-only and
owner-only (`0400`). The snapshot protects the retained names from normal log
rotation or overwrite. It does not protect against host or disk loss.

## Checksum Receipt

| File | SHA-256 |
| --- | --- |
| `symphony.log.1` | `a9c34724fdfae1893bba1c2f9cb82aa63dc183e9b967c6ccf3d2d080470dd1b6` |
| `symphony.log.2` | `09801d7a1d6c8c971ae97cf8befeca390b53fd38efd73f598ca8b35d194cb459` |
| `symphony.log.3` | `0d9e7df2463850797047b54bb09ac1343134b2f98b52a76d5da69448457868a8` |
| `symphony.log.4` | `34567490e1c95c53039531059ffc8fe9e9aa8c61e7e9dc8b07997f8cf375e7db` |
| `symphony.log.5` | `fdef2f1b9d169cf79a96befdb02623c061502a9b8462196eb1078c4a2a88c755` |

Each source hash matched its copied snapshot hash after the copy.

## Privacy And Retention

The raw logs may contain prompts, tool payloads, paths, credentials, or other
private material. Therefore:

- neither source nor snapshot is committed to Git
- no raw data has been copied to general-purpose external storage
- the snapshot must be retained until OXE-0.5 produces a redacted archive and
  its checksum/privacy receipt
- deletion requires the repository owner to verify the OXE-0.5 archive,
  automated secret-scan result, and human privacy review

An owner-approved, access-restricted external quarantine has not been
configured. This receipt satisfies source-in-place protection only; the
single-host loss risk remains explicit.
