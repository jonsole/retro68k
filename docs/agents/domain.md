# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## This repo

retro68k's domain documentation already exists in two places, and is the authority:

- `docs/spec/`: the hardware specs (spec 3 for every register). Every hardware change starts here.
- `docs/HANDOFF.md`: the working rules and recent decisions.

`GLOSSARY.md` and `docs/adr/` are for terms and decisions that don't belong in a spec.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This repo is single-context:

```
/
├── GLOSSARY.md
├── docs/
│   ├── adr/            ← decisions that don't belong in a spec
│   ├── spec/           ← the hardware specs (the authority)
│   └── guide/          ← the programming guide
├── fpga/rtl/
└── sim/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
