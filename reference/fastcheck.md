# Fast, parallel R CMD check

Runs the same checks as \`rcmdcheck::rcmdcheck()\` but restructured for
speed:

## Usage

``` r
fastcheck(
  path = ".",
  args = character(),
  build_args = character(),
  jobs = default_jobs(),
  profile = c("faithful", "fast"),
  cache_dir = default_cache_dir(),
  check_dir = NULL,
  tests = TRUE,
  examples = TRUE,
  vignettes = TRUE,
  manual = FALSE,
  error_on = c("never", "error", "warning", "note"),
  timeout = Inf,
  env = character(),
  quiet = FALSE
)
```

## Arguments

- path:

  Package source directory.

- args:

  Extra arguments for \`R CMD check\` (e.g. \`"–as-cran"\`).

- build_args:

  Extra arguments for \`R CMD build\`.

- jobs:

  Total parallelism (compile jobs and concurrent R processes).

- profile:

  Compiler profile, see \[accel_env()\].

- cache_dir:

  Persistent cache directory (compiler caches, cargo target dirs, test
  timings). Cache it in CI.

- check_dir:

  Where to put logs and results; a temp dir by default.

- tests, examples, vignettes:

  Run these parts of the check.

- manual:

  Build and check the PDF manual (needs LaTeX; slow).

- error_on:

  Signal an R error if a problem of at least this severity is found.

- timeout:

  Per-process timeout in seconds.

- env:

  Extra environment variables for every child process.

- quiet:

  Suppress progress messages.

## Value

An object of class \`fastcheck\`.

## Details

1\. \`R CMD build\` without building vignettes or the PDF manual
(vignettes are executed exactly once, in step 3, instead of in both
build and check). 2. The package is compiled \*\*once\*\*, from a stable
staging directory, with \`MAKEFLAGS=-j\<jobs\>\`, ccache for
C/C++/Fortran, sccache (if available) for Rust, and a persistent cargo
\`target/\` directory. 3. Concurrently, against that single
installation: \* \`R CMD check –install=check:\<log\>\` for all static
checks (DESCRIPTION, code, Rd/documentation, codoc, compiled code,
install-log warnings ...), \* the testthat suite, sharded over several
processes, \* the Rd examples, sharded over several processes, \* every
vignette in its own process.
