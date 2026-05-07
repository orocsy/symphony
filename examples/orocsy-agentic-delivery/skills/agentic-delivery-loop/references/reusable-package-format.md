# Reusable Package Format

Use the kit as a small portable package, not as one giant instruction file.

## Recommended Layout

```text
agentic-delivery-loop/
├── cli/
│   └── agentic_project.py
├── SKILL.md
├── references/
│   ├── miu-trace.md
│   ├── business-correction-loop.md
│   ├── project-bootstrap-cli.md
│   ├── symphony-linear-loop.md
│   ├── browser-e2e-gate.md
│   ├── review-hardening-loop.md
│   └── symphony-fork-workflow.md
├── project-templates/
│   ├── stacks/
│   ├── deploy/
│   └── feature-packs/
└── assets/templates/
    ├── AGENTS.next-project.md
    ├── linear-workstream.md
    ├── miu-execution.md
    ├── symphony-dispatch.md
    └── WORKFLOW.concurrent-symphony.template.md
```

## What Goes Where

| Artifact | Purpose |
| --- | --- |
| Skill | Tells Codex when to use the workflow and which reference to load. |
| References | Detailed behavior rules loaded only when relevant. |
| Templates | Copyable scaffolds for new projects and Linear issues. |
| CLI | Agent-invoked setup wrapper for project bootstrap. |
| Template packs | Stack/deploy/feature profiles recorded in each project. |
| Project examples | Concrete examples kept separate from ruless, kept separate from rules. |
| Symphony fork overlay | Optional place for reusable workflow examples and starter scripts. |

## Installation Options

1. **Global Codex skill:** copy the skill folder into `~/.codex/skills/`.
2. **Project-local skill:** copy into `<repo>/.codex/skills/`.
3. **Template repo:** keep this package in a dedicated repository and copy it
   into new projects.
4. **Symphony fork overlay:** keep Symphony-specific workflow templates in a
   fork such as `orocsy/symphony`.

Use the global skill for agent behavior. Use project-local copies when a
project needs its own customized business/design rules.
