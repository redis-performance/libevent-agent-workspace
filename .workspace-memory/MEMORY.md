# Workspace Memory — libevent-agent-workspace

Persistent memory index. One entry per file. Committed to main so all agent backends
share the same context.

<!-- Add entries below as you learn things about the project, optimization patterns,
     what worked, what didn't, and user preferences. -->

- Optimization target is OSS libevent only — evbuffer data plane (buffer.c), socket I/O
  batching, and epoll_ctl churn. Metric is ns/op + events/sec + syscall count, NEVER MB/s.
- The `libevent/test/bench*.c` harness is immutable. Each implementer variant builds in its
  own git worktree + isolated build dir (multi-file C library — no single-header swap).
- Heed ffc-agent-workspace's lesson: `__attribute__((hot/cold))` and `noinline` annotations
  repeatedly regressed there — treat any such tagging as a logged, revertible experiment.
