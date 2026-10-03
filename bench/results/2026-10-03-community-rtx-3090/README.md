# Community benchmark: RTX 3090, Ryzen 7 5800X

Measured on 2026-10-03 by [orangeswim](https://github.com/orangeswim), on a Windows
machine called Bill. This tests Strata 0.1.38 (= `main` at commit `99f3dbd` at test
time) with the Coder IQ1_M pack, one GPU, and a 204,800-token context limit.

Median cold-prompt throughput was **2,461 tok/s at ~100K prompt tokens and 2,172 tok/s
at ~196K**; decode of the retrieval answers ran at 97–107 tok/s, and a 196K-token
prompt re-sent with 36 new tokens was served in ~0.3 s from the conversation cache.
The workload is a 26-needle retrieval suite, not general chat or code generation; the
retrieval scores below are workload-specific.

## Hardware and software

- NVIDIA GeForce RTX 3090; 24,576 MiB reported VRAM; PCIe capability Gen4 x16. The
  engine's startup transfer probe reported 26.3 GB/s host-to-device. GPU clocks were
  not fixed. The engine's PCIe fraction stayed at its default (0.55).
- AMD Ryzen 7 5800X; 8 cores / 16 threads, DDR4-3200 (4x8 GB). The engine selected
  AVX2 (no AVX-512 on this CPU) and 7 expert-pool workers.
- 32 GB installed RAM; steady state during serving leaves ~0.5–1.2 GB free (the
  expert arena takes ~23.4 GB). Storage: the model volume read at ~0.35 GiB/s during
  load; device type not separately verified.
- Windows (SSH/Git Bash for control; the benchmark client runs from WSL on another
  machine over the network). NVIDIA driver 596.36.
- Source commit `99f3dbd` (tag v0.1.38, `main` at test time); locally compiled for
  sm_86 with CUDA 13.2 / MSVC 14.44; no vision helper.
- Nothing else used the GPU. The expert cache is the full-GPU one; other CPU
  services (a small web UI) remained running.

## Model and configuration

Model: the Coder (RCO-pruned for code/agentic use), installed by the regular
installer from the ISTA-DASLab GSQ-RCO artifacts:

- pack `coder-iq1_m` (kept experts, ~IQ3_S-class storage)
- `Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf` (native experts) and
  `...-00002-of-00002.gguf` (PLE)
- MTP draft from the installer's `Qwen/Qwen3.8-Flash-Next` fetch (`rt`)

The full run configuration is [engine-config.json](engine-config.json): `--kv k8v4`
(the hybrid INT8-K / Q4_0-V option), `--max-context 204800`, `--spec 4` with
`--suffix-draft 3`, `--expert-cache auto`, `--prefill auto`, and one environment
setting, `STRATA_PF_FUSED=1` (the fused int8 prompt experts, opt-in for the native
IQ packs). `--spec-min-p` is 0.35 rather than the 0.50 default: `--calibrate` picks
0.50 on this box, but on this machine's real traffic (short chat/code turns) 0.35
measured 3–8 tok/s faster at short context and neutral at long context. VRAM holds
7,660 expert slots (~14.9 GB); with everything loaded the engine reports ~0.45 GB
free.

## Workload

[needle26.sh](needle26.sh): 26 `[SECRET: WORD-KEY-nnnnn]` needles placed at even,
seed-shuffled depths in plain-text wiki corpus trimmed to the target token count
(~3.27 chars/token; the three source text files are ours - any large plain-text
corpus of known length works, and the script takes the paths as arguments). One
fact-check paragraph is inserted at 60% depth if the trim dropped it. The model is
asked to return all keys as a JSON array: greedy decoding (temperature 0, top_p 1),
512-token output cap, thinking disabled, non-streaming.

Each seed shuffles the needle order and depths (same token count, different
content), so the three runs per size are three different prompts. Every run makes
one cold main request (0 tokens reused) and one follow-up with 36 appended tokens
(cache reuse). Raw per-run numbers are in [runs.json](runs.json).

## Results

Cold prefill of the main request (0 tokens reused):

| prompt tokens | runs (tok/s) | median | decode of the answer |
|---|---|---|---|
| 99,583 | 2,387 / 2,467 / 2,461 | **2,461** | 91.9 / 106.8 / 107.4 |
| 195,897 | 2,175 / 2,172 / 2,167 | **2,172** | 97.0 / 106.2 / 102.6 |

Cache: the 196K follow-up (196,150 reused + 36 read) served in 298–303 ms; the
~100K follow-up in ~0.3 s. Draft acceptance on the answers: 185/202 to 226/259.

Retrieval (26 needles, greedy): 25/26 and 25/26 at ~100K; 21/26, 20/26, 25/26 at
~196K, with the misses clustered at 18–59% depth and no hallucinated keys. At this
context depth the greedy retrieval is not run-stable on this hardware: repeated
runs of one build move a few mid-depth needles in and out, so treat these as a
band (20–25 of 26 at ~196K, 25 of 26 at ~100K) rather than per-seed constants.
The fact-check question was answered correctly in every run.

Speed on this machine under the other settings we measured (same suite, cold 198K
prompts):

| config | 198K prefill tok/s | decode tok/s |
|---|---|---|
| `main`, MMQ prompt experts (no `STRATA_PF_FUSED`) | 2,042–2,090 | ~100 |
| `main` + `STRATA_PF_FUSED=1` (this report) | 2,167–2,175 | 97–107 |
| this report + PR #575 (split top-k) | 2,368–2,388 | 97–107 |

At ~100K prompts the split is within run noise of this report (2,387–2,467 vs
2,437).
