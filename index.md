# fastrcmdcheck

`fastrcmdcheck` is a much faster drop-in replacement for
[`rcmdcheck`](https://github.com/r-lib/rcmdcheck) and
`r-lib/actions/check-r-package` in CI. It runs the same `R CMD check`
machinery, restructured so that nothing is compiled twice, compiler work
is cached between CI runs, and the slow, independent parts of a check
run in parallel.

``` r

fastrcmdcheck::fastcheck(".", args = "--as-cran", error_on = "warning")
```

``` sh
Rscript -e 'fastrcmdcheck::fastcheck_cli()' --as-cran --error-on warning .
```

``` yaml
# GitHub Actions: replaces r-lib/actions/check-r-package
- uses: grantn5/fastrcmdcheck@main
  with:
    args: "--as-cran"
    error-on: "warning"
```

## Installation

### Users

Install with the following

``` r

remotes::install_github(
    repo = "grantn5/fastrcmdcheck"
  )
```

## GitHub Actions

Swap `r-lib/actions/check-r-package` for the action in your existing
check workflow. Everything before it (R, dependencies, pandoc) stays the
same. The action installs `ccache` (and `sccache` for Rust packages),
restores the compiler cache, installs `fastrcmdcheck` and runs the
check.

``` yaml
# .github/workflows/R-CMD-check.yaml
on:
  push:
    branches: [main]
  pull_request:

name: R-CMD-check

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with:
          use-public-rspm: true
      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          needs: check
      - uses: r-lib/actions/setup-pandoc@v2

      # was: - uses: r-lib/actions/check-r-package@v2
      - uses: grantn5/fastrcmdcheck@main
        with:
          args: "--as-cran --no-manual"
          error-on: "warning"
```

Inputs:

| Input | Default |  |
|----|----|----|
| `path` | `"."` | package directory |
| `args` | `"--as-cran"` | extra `R CMD check` arguments, space separated |
| `error-on` | `"warning"` | `never`, `error`, `warning` or `note` |
| `profile` | `"faithful"` | `faithful` or `fast` (see [Compiler profiles](#compiler-profiles)) |
| `jobs` | all cores | number of parallel workers |
| `cache-version` | `"1"` | bump to throw away the compiler caches |
| `upload-results` | `"true"` | upload the check directory as an artifact on failure |

A common setup is `profile: "fast"` on pull requests and the default
`faithful` profile on `main`.

## Code format

We use [air](https://github.com/posit-dev/air) to keep the code
consistent. The style is set in `air.toml`. To format, run:

``` sh
air format .
```

## Benchmarks

Wall-clock seconds for `--as-cran --no-manual`, every run pinned to the
same 4 cores (a GitHub runner), measured with `bench/bench.sh` on
2026-10-26. `rcmdcheck -j` is `rcmdcheck` with `MAKEFLAGS=-j4`. *Cold*
means an empty `cache_dir` and *warm* means a second run with an
unchanged package. `fast` is `profile = "fast"`. All scenarios report
the same errors, warnings and notes as `rcmdcheck`.

| Package | rcmdcheck | rcmdcheck -j | cold | warm | fast cold | fast warm | warm speed-up |
|----|---:|---:|---:|---:|---:|---:|---:|
| `cppheavy` (C++, many TUs) | 93.6 | 48.4 | 23.2 | 15.5 | 22.8 | 15.3 | **6.0x** |
| `fs` (CRAN 1.6.5, bundled libuv) | 51.4 | 35.4 | 18.9 | 13.7 | 16.9 | 13.7 | **3.8x** |
| `rheavy` (pure R, many tests) | 38.5 | 33.8 | 12.2 | 12.3 | 11.4 | 11.4 | **3.1x** |
| `rustpkg` (Rust via cargo) | 30.5 | 29.0 | 20.4 | 15.1 | 15.1 | 11.0 | **2.0x** |

Most of the warm-run speed-up comes from not compiling again, which
doesn’t depend on core count. On fewer cores (e.g. a 2-core runner) the
cold builds and the parallel tests (`rheavy`) slow down, but warm runs
keep most of their advantage. The online clock check was off for every
tool (see `_R_CHECK_SYSTEM_CLOCK_` below). With it on, any tool can lose
up to about 60s per run when the time servers can’t be reached.

## Why `rcmdcheck` is slow, and what changes

What `rcmdcheck()` does, all serially:

1.  `R CMD build`: installs the package (**compile \#1**) to build the
    vignettes (**vignettes run \#1**), then builds the PDF manual
    (LaTeX).
2.  `R CMD check`: installs the package again from the tarball
    (**compile \#2**, serial `make`, no cache), runs ~50 static checks,
    then the examples, then the whole test suite in one process, then
    rebuilds the vignettes (**vignettes run \#2**) and the PDF manual
    again.

C++/Rust code gets compiled twice per run and from scratch on every CI
run. Rust crates (with `lto = true` / `codegen-units = 1`, as in the
common templates) dominate many check runs.

What
[`fastcheck()`](https://grantn5.github.io/fastrcmdcheck/reference/fastcheck.md)
does:

| Step | What happens | Why it is faster |
|----|----|----|
| build | `R CMD build --no-build-vignettes --no-manual` | no install, no vignettes, no LaTeX (a few seconds) |
| install | **one** `R CMD INSTALL` from a stable staging dir with `MAKEFLAGS=-jN`, `ccache` for C/C++, `sccache` for Rust when available, and the cargo `target/` dir saved between runs | compiles once, in parallel; on warm runs only changed translation units / crates compile |
| static checks | `R CMD check --install=check:<log> --library=<lib>` (CRAN’s own “already installed” mode) | reuses the install, still analyses the install log for compiler warnings, symbol tables etc. |
| tests | testthat files sharded over N processes (balanced by the previous run’s per-file timings); each shard gets a private copy of `tests/`; non-testthat `tests/*.R` run like `R CMD check` (`R CMD BATCH`, `.Rout.save` diffs) | the usual bottleneck now runs in parallel |
| examples | Rd examples extracted with [`tools::Rd2ex()`](https://rdrr.io/r/tools/Rd2HTML.html) and run in N processes, each in its own working directory, per-topic clean env/RNG/options/devices like `R CMD check` | parallel |
| vignettes | every vignette rebuilt in its own process against the installed package | executed once instead of twice, in parallel |

Static checks, test shards, example shards and vignettes all run at the
same time in one process pool (`jobs`, default: all cores). The result
has errors, warnings and notes like `rcmdcheck`, plus a `checks` data
frame, timings and the log directory.

### Compiler profiles

- `profile = "faithful"` (default): R’s compiler flags are untouched, so
  the install log and the compiler warning checks are the same as
  `R CMD check`. All speedups are structural (one compile, parallel
  make, caching, concurrency).
- `profile = "fast"`: also compiles C/C++ with `-O0 -g0` and Rust with
  `lto=false`, `codegen-units=256`, `opt-level=1` (through
  `CARGO_PROFILE_RELEASE_*` env vars, which override `Cargo.toml`). Much
  faster cold builds of heavy C++/Rust; meant for PR CI.
  Optimisation-dependent warnings (e.g. `-Wmaybe-uninitialized`) can be
  missed, so keep a `faithful` job on main and for releases.

## Fidelity: what is (and isn’t) identical to `R CMD check`

- All static checks are R’s own `R CMD check` code (`--install=check:`
  is the mode CRAN uses for already-installed packages).
- Test failures, example errors and vignette errors are all reported as
  `ERROR`.
- Differences:
  - Examples: per-topic timings and `--timings` output are not produced,
    and `Examples/*.Rout.save` comparisons are not done.
  - Vignettes are woven (all code runs) but not tangled/re-run
    separately, and the `inst/doc` consistency checks of `R CMD check`
    are skipped (`--ignore-vignettes`).
  - testthat shards run in separate processes. Tests that depend on
    running after another *file* in the same process (state leaking
    between files) can behave differently. Tests that write to fixed
    paths inside `tests/` are fine (each shard has its own copy); tests
    writing to fixed paths elsewhere (e.g. `~`) may collide.
  - The PDF manual is skipped unless `manual = TRUE` / `--manual`. The
    Rd checks (`checkRd`, codoc, usage, cross-references, missing docs)
    all still run.
  - `_R_CHECK_SYSTEM_CLOCK_` defaults to `FALSE`. With `--as-cran`, R
    otherwise asks up to three internet time servers for the current
    time, one after another, to catch a machine whose clock is wrong.
    When the servers can’t be reached (common on CI and behind
    firewalls), each one can take up to 60s before failing, and the
    check still ends with only “NOTE: unable to verify current time”.
    With the default, the future file timestamps check still runs, but
    compares against the system clock (NTP-synced on GitHub runners).
    Set `_R_CHECK_SYSTEM_CLOCK_=TRUE` to get R’s behaviour back.

## Options

| R argument | CLI | default |
|----|----|----|
| `args` | any unknown `--flag` | [`character()`](https://rdrr.io/r/base/character.html) |
| `jobs` | `-j/--jobs`, `$FASTCHECK_JOBS` | all cores |
| `profile` | `--profile` | `"faithful"` |
| `cache_dir` | `--cache-dir`, `$FASTCHECK_CACHE_DIR` | `tools::R_user_dir("fastrcmdcheck", "cache")` |
| `check_dir` | `--check-dir` | temp dir |
| `error_on` | `--error-on` | `"never"` (R) / `"warning"` (CLI) |
| `tests`, `examples`, `vignettes` | `--no-tests`, `--no-examples`, `--no-vignettes` | `TRUE` |
| `manual` | `--manual` | `FALSE` |
| `timeout` | `--timeout` | none |
|  | `--json FILE` | write results as JSON |

## CI caching

Persist `cache_dir` between runs (the action does this with
`actions/cache`). It contains the ccache/sccache stores, the saved cargo
`target/` dirs, the staged sources and per-file test timings. Install
`ccache` (`apt-get install ccache`) and, for Rust packages, `sccache`.
The action does both. Package dependencies are still installed by
`r-lib/actions/setup-r-dependencies` (which already caches).

Rust: the saved `target/` dir is reused when the package’s `Makevars`
builds into `src/<crate dir>/target` (the default layout of rextendr /
savvy / the “hellorust” templates). If a `Makevars` deletes `target/`
after building (some CRAN-oriented templates do when `NOT_CRAN` is
unset), only sccache helps.

## Development

``` sh
R CMD INSTALL .
NOT_CRAN=true Rscript -e 'testthat::test_local()'
Rscript bench/make-fixtures.R /tmp/fixtures      # synthetic C++ / Rust / R packages
bench/bench.sh /tmp/fixtures /tmp/bench-out 4      # rcmdcheck vs fastcheck on 4 cores
```
