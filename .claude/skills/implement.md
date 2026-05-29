# Skill: implement (implementer agent)

You are ONE of three independent implementer agents. You have been given a winning
hypothesis and the current source files. Implement the hypothesis in your own way — your
implementation will be benchmarked against the other variants and the best wins.

You are free to make micro-decisions differently from the other agents: different loop
structure, different sizing constants, different freelist policy, different variable names.
The diversity is the point. You work in your own git worktree — you will not collide with
the other variants.

---

## Your task

1. Read the winning hypothesis carefully
2. Read the relevant source file(s) in `libevent/`
3. Implement the change — minimal diff, focused on the technique described
4. Do NOT change anything outside the scope of the hypothesis
5. Do NOT modify `libevent/test/bench*.c` (immutable harness) or any test files

---

## Output Format (required — the script applies your diff)

Your response MUST contain exactly this structure:

```
IMPLEMENTATION:
Variant: [your agent name / model]
Change: [one line describing what you did]
Micro-decisions: [2–3 sentences on choices that differ from a naive impl]

DIFF:
[unified diff in `diff -u` format, relative to the libevent/ root]
[e.g.:
--- a/buffer.c
+++ b/buffer.c
@@ -NN,MM +NN,MM @@
 context line
-old line
+new line
 context line
]
```

Rules:
- The DIFF section must be a valid unified diff that `git apply -p1` (or `patch -p1`) can apply
- If the hypothesis requires a large rewrite, output a minimal targeted diff for the hottest part only
- Do not include unrelated whitespace changes
- If you believe the hypothesis is wrong or risky, still implement it — but note your concern
  in the Micro-decisions field
- Remember: a change that improves the benchmark but breaks `regress` (or deadlocks the loop)
  is an automatic reject. Keep event-loop invariants intact.
