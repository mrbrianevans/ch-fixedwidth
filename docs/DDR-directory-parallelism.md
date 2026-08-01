# DDR: Directory multi-file parallelism

**Status:** Accepted  
**Date:** 2026-08-01  
**Related code:** `src/file_convert.zig` (`processDirectory`, `processOneLocalFile`, `processParallel`)

## Context

The native CLI accepts a directory of Companies House snapshot `.dat` files and writes one company CSV and one person CSV per input file.

Expected production shape of a directory argument:

- Almost always **about eight** files (never many more)
- Sizes typically **~200 MB to 1–2 GB** (never tiny fixtures as the main case)
- Run on a modern multi-core machine (e.g. Intel Core i7 class)
- Conversion is usually **CPU-bound** on large snapshots once I/O is local NVMe-class storage

Single-file input already supports **within-file** multi-threading: the file is split on line boundaries by seek offsets; workers write part CSVs that are concatenated (`processParallel`).

## Decision drivers

- Wall-clock time for a full directory run
- Sustained CPU utilisation for most of the run (not only the first few seconds)
- Reuse of the proven large-file path
- Predictable peak memory and I/O behaviour
- Avoid nested thread pools (file-level threads each spawning range workers)

## Options considered

### Option A — File-level parallelism

Process several files at once. Each file runs a **single sequential** stream on one thread (or one worker), so cores are assigned **across files**, not inside a file.

| Merits | Drawbacks |
|--------|-----------|
| Natural fit when *N* files ≈ *N* cores and sizes are similar | **Imbalance:** 200 MB files finish long before 1–2 GB files; remaining work is stuck on few single-threaded large files |
| Independent work; simple “one file, one pipeline” model | Cannot put idle cores onto a still-running large file |
| Overlaps I/O of multiple sequential readers early in the run | Peak memory and open writers scale with concurrent files |
| | Does not use the tuned seek-split path for directory batches |

Makespan lower bound for **unsplittable** per-file jobs is roughly  
`max(total_work / cores, largest_file_work)`.  
With mixed 200 MB and 1–2 GB files, **largest_file_work** often dominates → long under-utilised tail.

### Option B — Within-file parallelism, one file at a time

Process the directory as a **queue of files**. For each file, use the same multi-core seek split as a single-file CLI argument; only then start the next file.

| Merits | Drawbacks |
|--------|-----------|
| Every large file can use **most/all cores** for its entire lifetime | No overlap between files (wall time ≈ sum of per-file parallel times) |
| Wall time closer to `total_work / cores` when within-file scaling is good | Multi-offset reads are slightly less “pure sequential” than one stream (usually fine on SSD when CPU-bound) |
| Matches the path already validated for multi-GB snapshots | Many *tiny* files would pay range-setup/concat overhead repeatedly (not our workload) |
| Predictable peak memory (one file’s worker set) | |
| No nested threading | |

### Option C — Hybrid (not chosen)

Heuristics or flags: file-level when many similar medium files; within-file when few large files; or a global queue of `(file, byte-range)` tasks.

Deferred: more complexity and testing surface than the expected eight-file, mixed large workload needs today.

### Nested A+B (rejected)

Running file-level workers that each call within-file `processParallel` oversubscribes cores, multiplies part-directory logic, and blows peak memory. Not considered a viable third design.

## Decision

**Choose option B** for directory input:

1. List top-level `*.dat` files (sorted).
2. For each file, call the same local path as a single-file run (`processOneLocalFile` → `processParallel` when multi-core, else sequential stream).
3. Continue after a per-file failure so other files still convert; non-zero exit if any file failed.

## Consequences

- Directory mode and single-file mode share one multi-threading implementation.
- On an i7-class machine with ~8 mixed large snapshots, cores stay busy on each 1–2 GB file instead of idling after the 200 MB files finish under option A.
- Peak concurrent parse pipelines stay at one file’s worker count.
- If a future workload is “dozens of equal medium files,” revisit option A or C; that is explicitly **not** the current product shape.

## References

- CLI behaviour: [README.md](../README.md) (Run / directory input)
- Contributor notes: [development.md](development.md)
- Implementation: `processDirectory` in `src/file_convert.zig`
