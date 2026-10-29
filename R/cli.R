#' Command line entry point
#'
#' `Rscript -e 'fastrcmdcheck::fastcheck_cli()' -- [options] [path]`, or the
#' `fastcheck` script in `system.file("bin", package = "fastrcmdcheck")`.
#' Exits non-zero when problems at or above `--error-on` are found.
#'
#' @param argv Command line arguments.
#' @export
fastcheck_cli <- function(argv = commandArgs(TRUE)) {
  usage <- "Usage: fastcheck [options] [path]

Options:
  -j, --jobs N          parallelism (default: all cores, or $FASTCHECK_JOBS)
  --profile P           faithful (default) or fast (-O0 C/C++, no-LTO Rust)
  --cache-dir D         persistent cache (default: $FASTCHECK_CACHE_DIR)
  --check-dir D         where logs and results go
  --error-on L          never, error, warning (default) or note
  --json FILE           write results as JSON
  --manual              also build/check the PDF manual (needs LaTeX)
  --no-tests --no-examples --no-vignettes
  --timeout SECS        per-process timeout
  --build-arg ARG       extra argument for R CMD build (repeatable)
  Anything else starting with '--' is passed to R CMD check (e.g. --as-cran).
"
  opts <- list(
    path = ".",
    jobs = default_jobs(),
    profile = "faithful",
    cache_dir = default_cache_dir(),
    check_dir = NULL,
    error_on = "warning",
    json = NULL,
    manual = FALSE,
    tests = TRUE,
    examples = TRUE,
    vignettes = TRUE,
    timeout = Inf,
    args = character(),
    build_args = character()
  )
  argv <- argv[!argv %in% c("--args", "--")]
  i <- 1
  val <- function() {
    if (i + 1 > length(argv)) {
      stop("missing value for ", argv[i], call. = FALSE)
    }
    argv[i + 1]
  }
  while (i <= length(argv)) {
    a <- argv[i]
    own <- c(
      "--jobs",
      "--profile",
      "--cache-dir",
      "--check-dir",
      "--error-on",
      "--json",
      "--timeout",
      "--build-arg"
    )
    if (sub("=.*$", "", a) %in% own && grepl("=", a, fixed = TRUE)) {
      kv <- regmatches(a, regexpr("=", a), invert = TRUE)[[1]]
      argv <- append(argv[-i], kv, after = i - 1)
      a <- argv[i]
    }
    step <- 2
    switch(
      a,
      "-h" = ,
      "--help" = {
        cat(usage)
        return(invisible(0))
      },
      "-j" = ,
      "--jobs" = opts$jobs <- as.integer(val()),
      "--profile" = opts$profile <- val(),
      "--cache-dir" = opts$cache_dir <- val(),
      "--check-dir" = opts$check_dir <- val(),
      "--error-on" = opts$error_on <- val(),
      "--json" = opts$json <- val(),
      "--timeout" = opts$timeout <- as.numeric(val()),
      "--build-arg" = opts$build_args <- c(opts$build_args, val()),
      "--manual" = {
        opts$manual <- TRUE
        step <- 1
      },
      "--no-tests" = {
        opts$tests <- FALSE
        step <- 1
      },
      "--no-examples" = {
        opts$examples <- FALSE
        step <- 1
      },
      "--no-vignettes" = {
        opts$vignettes <- FALSE
        step <- 1
      },
      {
        step <- 1
        if (startsWith(a, "-")) opts$args <- c(opts$args, a) else opts$path <- a
      }
    )
    i <- i + step
  }

  res <- tryCatch(
    fastcheck(
      opts$path,
      args = opts$args,
      build_args = opts$build_args,
      jobs = opts$jobs,
      profile = opts$profile,
      cache_dir = opts$cache_dir,
      check_dir = opts$check_dir,
      tests = opts$tests,
      examples = opts$examples,
      vignettes = opts$vignettes,
      manual = opts$manual,
      timeout = opts$timeout,
      error_on = "never"
    ),
    error = function(e) {
      message("fastcheck failed: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(res)) {
    quit(status = 2)
  }
  if (!is.null(opts$json)) {
    jsonlite::write_json(
      unclass(res),
      opts$json,
      auto_unbox = TRUE,
      pretty = TRUE
    )
  }
  thr <- match(opts$error_on, c("never", "error", "warning", "note")) - 1
  n <- c(length(res$errors), length(res$warnings), length(res$notes))
  quit(status = if (thr > 0 && any(n[seq_len(thr)] > 0)) 1 else 0)
}
