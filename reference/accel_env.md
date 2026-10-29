# Environment that accelerates compiling an R package

Environment that accelerates compiling an R package

## Usage

``` r
accel_env(
  cache_dir,
  jobs = parallel::detectCores(),
  profile = c("faithful", "fast"),
  ccache = TRUE,
  sccache = TRUE
)
```

## Arguments

- cache_dir:

  Directory holding the persistent caches (ccache, sccache). Persist it
  between CI runs (e.g. with \`actions/cache\`).

- jobs:

  Number of parallel compile jobs.

- profile:

  \`"faithful"\` keeps R's compiler flags untouched (results match a
  plain \`R CMD check\`). \`"fast"\` additionally compiles C/C++ with
  \`-O0 -g0\` and Rust without LTO at \`opt-level=1\`; much faster for
  heavy C++/Rust code but may hide optimisation-dependent compiler
  warnings.

- ccache, sccache:

  Use the compiler cache if it is on the \`PATH\`.

## Value

Named character vector of environment variables.
