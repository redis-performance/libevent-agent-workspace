# Skill: bench

Run the benchmark workloads and report results. **Never report MB/s** — libevent is an
event loop; the metrics are ns/op per fired event, events/sec, and syscall count.

## Steps

1. Build libevent (static, RelWithDebInfo) + OSS benchmarks with current source:
   ```bash
   scripts/build-bench.sh
   ```

2. Run the workloads (params come from `config/workload.toml`, pinned cores, median of N):
   ```bash
   EXP=EXP-NNN scripts/run-bench.sh
   ```
   This runs `bench` (pipe/event throughput) and `bench_cascade` (event-propagation latency),
   each warmed up then repeated, writing JSON to `experiments/EXP-NNN/bench-results/`.

3. Report per workload:
   - **events/sec** (throughput)
   - **ns/op** (time per fired event)
   - **syscall count** (from the profile step, if available)
   Compute Δ% vs the last accepted entry in `experiments/EXPERIMENTS.md`.

## Output Format

```
Workload: cascade (bench -n100 -a1 -w100)
  events/sec : NNNNN   (Δ +N.N%)
  ns/op      : NN.N    (Δ -N.N%)

Workload: cascade_chain (bench_cascade -n100)
  ns/op      : NN.N    (Δ -N.N%)
```

## Notes

- `sudo` is needed for perf hardware counters / syscall counts (collected in the profile step)
- Pin to the cores in `config/workload.toml` (`taskset`) and keep them fixed across baseline + experiment
- Run ≥ 3 times and take the median; if variance > 5%, raise `repetitions` in workload.toml
- Validate any accept/reject with two runs: perf-on for direction, perf-off for the true delta
- The FIRST run on any machine, with unmodified libevent, is the BASELINE — save it tagged
  `<date>-<machine>-BASELINE.json`
