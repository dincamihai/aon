---
column: Done
---

# aon launch: wrong role selected (sun → joana)
## Problem

`aon launch sun` incorrectly identifies/launches as joana instead of sun.

## Reproduction

```bash
cd ~/repos/workers
aon launch sun
# Claude launches with AON_ROLE=joana (expected: AON_ROLE=sun)
```

## Expected Behavior

Should launch claude with AON_ROLE=sun, using sun's credentials and prompt.

## Investigation Needed

- Check role parsing logic in aon script (role argument matching)
- Verify aon.toml roster is parsed correctly
- Check if there's role name collision or typo
- Trace where "joana" is being injected
- Check if it's always wrong or only for certain roles

Roster order in aon.toml: mid, tim, joana, sun, rona
