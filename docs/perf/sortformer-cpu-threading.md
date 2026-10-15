# Sortformer CPU threading — elementwise row/channel schedule

**Result class: SELF-SPEEDUP / MAINTENANCE.** Same-binary feature gate
(`FW_SORTFORMER_ELEMENTWISE_PARALLEL=0` restores the serial loops). This is
not a campaign win. The 3–4× target from the threading review is not met on
this host.

Branch base: `35f7d37f8f15338460bf20807064eb94451e119c` (v0.9.3, the commit
the fw-cuda image pins). Fork PR only. Nothing was opened against
`Dicklesworthstone/franken_whisper`.

## What changed

`src/sortformer_inference.rs` splits independent rows, channels, or chunks
across the current rayon pool. Each element keeps the original left-to-right
float operations. There is no cross-thread reduction inside an element.

Parallel:

- softmax over score rows (attention heads stay serial, so a head's GEMM is
  not nested under another pool split)
- swish and sigmoid, grain 8192 elements
- GLU rows, depthwise convolution rows (kernel taps 0..8 unchanged), BatchNorm
  rows
- relative-position sin/cos rows
- attention Q/K/V/position packing and context scatter, one frame per task
- grouped Conv2d, one output channel per task

Left serial on purpose:

- ReLU. On the steady-state 609×2048 shape the split was slower (0.47 ms
  serial vs 0.73 ms at 4 threads on the pre-final binary). The v0.9.3 loop
  stays.
- TopK / speaker-cache compression (order-sensitive).
- Dense im2col GEMM. FrankenTorch already splits the GEMM.
- LayerNorm in `src/native_engine/nn.rs` (already row-parallel).

The diarization hot path skips the unused depthwise channel-major transpose.
The trace API still builds it. Both kill-switch arms skip it. The unmodified
v0.9.3 binary, which still builds the transpose, produced the same
probabilities and turns, so the skip does not change output bits.

## Identity

Fixture: `tests/fixtures/sortformer_representative_speech.wav`.

- espeak-ng `en-us`, then `en-gb` (`-p 30`), then `en-us`, concatenated and
  resampled with ffmpeg to 16 kHz mono s16.
- 412109 samples, 25.757 s.
- Model: Sortformer v2.1 f32
  `weights.safetensors` sha256
  `487fa30cb0aa9799c77bd9985e6787962c3991fab8d4d576a4f1221d45298f6a`.
- Call: `SortformerSession::diarize` (streaming graph, default L7/L8
  postprocess). Rayon pool of 4 threads for the reference arm.

Committed golden
`tests/fixtures/sortformer_v093_representative_diarization.json`:

- 322 frames, 1288 f32 probabilities, 7 turns.
- Written by the serial elementwise arm of this branch.
- Compared to a separate binary built from unmodified `35f7d37` (worktree,
  same model, same wav decode `i16/32768`, 4 threads, same `release-perf`
  flags including the codegen-unit override below). Probability hex and all
  7 turn `start_bits` / `end_bits` / `speaker` values matched.

Same-binary check (`sortformer_cpu_threading_bench`, passed): serial@4
probabilities and turn bits match serial and parallel at 1, 4, and 12
threads.

Always-on unit test `sortformer_parallel_elementwise_matches_serial_oracle_bits`
(passed, debug and the module suite 42/0): swish, ReLU, sigmoid, softmax
rows, BatchNorm, GLU, depthwise k=9 pad=4, and relative position match
independent scalar oracles bit-for-bit at 4 threads. The serial branch of
swish matches that oracle too.

A pure two-tone fixture was rejected for the golden. It produced 680 frames
but zero turns (max probability 0.023). The speech fixture is what the
committed golden records.

## Host and build

- CPU: `Intel(R) Xeon(R) Processor` under a hypervisor, 4 cores, 1 thread per
  core, 1 NUMA node, 15 GiB RAM, no swap.
- `cpufreq` scaling governor is not exposed (`unknown`). No
  `energy_performance_preference`. Not a campaign host.
- Binary: nightly 2026-07-20, profile `release-perf` (opt-level 3, thin LTO,
  line tables), `-C target-cpu=x86-64-v3`.
- The `franken_whisper` crate was compiled with `codegen-units=8` and
  `-Z threads=1`. `codegen-units=1` was SIGKILL'd on this machine (rustc RSS
  passed 12 GiB). Dependencies stayed at the profile default
  (`codegen-units=1`). The unmodified v0.9.3 binary used the same override.
- Requested rayon threads 1, 4, and 12. Only 4 hardware threads exist, so the
  12-thread rows are oversubscribed and are not 12-core scaling.

## Benchmark

Per-op times are one steady-state call (609 frames), not a full layer stack.
Median of repeated calls (at least 3, or until 150 ms, cap 20). End-to-end is
one warmup plus three measured `diarize` calls; the reported value is the
median. At 1 thread the parallel arm does not split
(`current_num_threads() > 1` is false), so that pair is the same loops plus
noise.

### Per-op milliseconds

| threads | mode | swish 609×2048 | softmax 8×609×609 | GLU 609×512 | depthwise 609×512 k9 | BatchNorm 609×512 | ReLU 609×2048 | sigmoid 609×512 | relative pos 609 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | serial | 3.537 | 8.779 | 0.899 | 2.848 | 0.628 | 0.482 | 0.798 | 3.248 |
| 1 | parallel | 3.466 | 9.112 | 0.898 | 2.827 | 0.624 | 0.473 | 0.777 | 3.264 |
| 4 | serial | 3.463 | 8.686 | 0.923 | 2.870 | 0.631 | 0.471 | 0.785 | 3.262 |
| 4 | parallel | 1.616 | 3.306 | 0.322 | 0.901 | 0.416 | 0.468 | 0.272 | 1.173 |
| 12 | serial | 3.462 | 8.570 | 0.924 | 2.813 | 0.624 | 0.475 | 0.780 | 3.255 |
| 12 | parallel | 1.733 | 3.336 | 0.326 | 0.810 | 0.356 | 0.465 | 0.296 | 0.987 |

4-thread ratios (serial / parallel): swish 2.14×, softmax 2.63×, GLU 2.87×,
depthwise 3.19×, BatchNorm 1.52×, ReLU 1.01× (kept serial), sigmoid 2.89×,
relative position 2.78×.

### End-to-end `diarize` on the 25.757 s speech fixture

| threads | serial median ms | parallel median ms | same-thread ratio | vs 1-thread serial |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1283.418 | 1306.902 | same loops (noise) | 1.00× |
| 4 | 1031.870 | 778.971 | 1.32× | 1.65× |
| 12 | 1046.767 | 864.230 | 1.21× | 1.49× |

4-thread runs, ms, sorted: serial 995.1 / 1031.9 / 1038.2; parallel 755.7 /
779.0 / 787.7.

GEMM scaling on this VM is weak: 4-thread serial (elementwise still serial,
GEMMs already split) is only 1283/1032 = 1.24× over 1 thread. The review's
2.9× GEMM figure at 4 threads, and the 3–4× diarization target at 12 physical
cores, were not reproduced here. Parallel elementwise work removes the serial
tail that this machine can actually use: 1.32× at 4 threads on this clip.

## Upstream draft

Title: Parallelize Sortformer elementwise loops without changing output bits

CPU Sortformer diarization already splits the big GEMMs across rayon, then
sits on serial softmax, swish, depthwise convolution, GLU, and BatchNorm.
Those loops are independent per row or channel. This change runs them on the
current rayon pool and leaves the float operations inside each row in their
original order.

Output matches unmodified v0.9.3 (`35f7d37`) bit-for-bit on a 25.8 s
two-voice fixture: 1288 f32 probabilities and 7 speaker turns. A same-binary
kill switch, `FW_SORTFORMER_ELEMENTWISE_PARALLEL=0`, restores the serial
loops. ReLU stays serial; splitting it was slower.

On a 4-core Xeon VM (x86-64-v3, release-perf, Sortformer v2.1 f32), 4-thread
diarization of that clip went from 1032 ms serial elementwise to 779 ms
parallel (1.32×). Against 1 thread the same run is 1.65×. Twelve requested
threads are oversubscribed on this host and are slower than four. This is a
self-speedup, not a claim against another engine, and it is not the 3–4×
expected once the GEMMs are already bandwidth-bound on a wider machine.
