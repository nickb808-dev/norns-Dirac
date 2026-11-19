# ENGINE-PROVENANCE

`engine/Dirac.{h,cpp}` is a **verbatim vendored copy** of the canonical Dirac
engine from the ER-301 repo (`dirac`), taken at **v0.2.10**.

Rules of the road:

1. **Do not develop the engine here.** The ER-301 repo is upstream. If a DSP
   bug is found (in either place), fix it upstream first, then hand-copy the
   change here and run `make hosttest` — the ported ER-301 test suite
   (`test/host/main.cpp`, 17 suites) verifies the sync.
2. **Record every sync** below.
3. Wrapper / shim / script code (`norns/`, `ugen/`, `lib/`, `dirac.lua`) is
   native to THIS repo and free to evolve.

`make verify-vendor` diffs `engine/` against an upstream checkout and fails on
any difference, so a silent local edit cannot survive a build:

```
make verify-vendor UPSTREAM=../dirac
```

| Date       | Upstream version | What was synced |
|------------|------------------|-----------------|
| 2026-08    | v0.2.10          | Initial vendoring (engine + the 17-suite host harness). |
| 2026-11-18 | v0.2.12 (`b6017bf`) | Engine: 0.2.11 in-tune grains (sub-sample read positions), sanitize() on every control, integer dials; 0.2.12 removes Color (one inlet fewer: wrapper enum, `Dirac.sc.in`, `Engine_Dirac.sc`, `params.lua`, stub test follow). Harness: upstream's 0.2.12 `test/host/main.cpp` 3-way-merged with this repo's `nb()` block-count conversion (new `pitch` / `nan` suites wrapped too; `colort` dropped). Builds gain `-fno-finite-math-only`, as upstream. References regenerated: `ident-v0.2.12.bin` from upstream's own harness (bit-identical to ours), `-fl64` from ours. Pi `portcheck`: PASS, max diff -99.3 dBFS. |

---

## Why verbatim, and not a submodule

The tapdirac port already runs this way and it works. A submodule would pin the
engine more strictly, but it makes the norns repo unusable as a norns script
install target — `;install <url>` clones one repo, and a script that arrives
with an empty `engine/` directory is worse than one carrying a copy it can
prove is current.

The proof is the point: **`make verify-vendor` plus 17 passing suites** is a
stronger guarantee than "there is a submodule pointer somewhere", because it
checks the thing that actually matters (does this code behave like upstream)
rather than the thing that is easy to check (is the hash the same).

## What is NOT vendored

`DiracFieldGraphic.h` — the ER-301 grain-field scope. It is v2 work here (see
`docs/NORNS-PORT.md`, "The screen"), and vendoring a file nothing compiles
would be dead weight that still has to be kept in sync. Copy it when the scope
is actually built.
