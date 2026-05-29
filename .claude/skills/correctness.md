# Skill: correctness

The mandatory gate before ANY benchmark. A broken or hanging event loop is never
benchmarked. Two tiers: LIGHT (every iteration) and FULL (only on accept).

```bash
scripts/verify-correctness.sh            # LIGHT
scripts/verify-correctness.sh --full     # FULL
```

---

## LIGHT gate (every iteration — fast)

1. Build the changed variant (CMake, the variant's isolated build dir).
2. Run the relevant `regress` subset under **per-test hang timeouts** (`timeout(1)`):
   - `regress` core loop tests
   - `regress_buffer` (evbuffer changes)
   - `regress_bufferevent` (bufferevent changes)
   - `regress_et` (edge-trigger / backend changes)
   - Timeouts: CPU-bound tests 30s, socket-I/O tests 60s. A timeout = FAIL (deadlock).
3. Any failure or timeout → discard the variant, do NOT benchmark.

Pick the subset by what the diff touches (`buffer.c` → regress_buffer, etc.), but when in
doubt run the whole core suite — event.c/evmap.c/epoll.c/signal.c are cross-coupled.

---

## FULL gate (only before accepting)

1. **All backends** — re-run `regress` forcing each backend off in turn:
   ```bash
   EVENT_NOEPOLL=1 ./test/regress
   EVENT_NOSELECT=1 ./test/regress
   EVENT_NOPOLL=1   ./test/regress
   EVENT_NOKQUEUE=1 ./test/regress   # SKIP (not fail) backends unavailable on this OS
   ```
2. **ASAN** — build with `-fsanitize=address`, run the subset. No leaks / overflows.
3. **TSAN** — build with `-fsanitize=thread`, run the subset with a maintained suppression
   file for known-benign signal/deferred-queue races. Required for any Tier-6 (lock) change.

Default to the full `regress` suite on accept. Do NOT use a changed-file test-skipping
heuristic to narrow FULL — only narrow with an explicit, logged whitelist.

---

## Output Format

```
LIGHT gate:
  build            : ok
  regress_buffer   : pass (12/12)
  regress core     : pass (88/88)   [no timeouts]
  → PASS / FAIL

FULL gate (accept only):
  backends: epoll ✓  select ✓  poll ✓  kqueue (skipped)
  ASAN    : clean
  TSAN    : clean (3 suppressions)
  → PASS / FAIL
```
