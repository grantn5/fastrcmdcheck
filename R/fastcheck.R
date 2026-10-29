#' Fast, parallel R CMD check
#'
#' Runs the same checks as `rcmdcheck::rcmdcheck()` but restructured for
#' speed:
#'
#' 1. `R CMD build` without building vignettes or the PDF manual (vignettes
#'    are executed exactly once, in step 3, instead of in both build and
#'    check).
#' 2. The package is compiled **once**, from a stable staging directory, with
#'    `MAKEFLAGS=-j<jobs>`, ccache for C/C++/Fortran, sccache (if available)
#'    for Rust, and a persistent cargo `target/` directory.
#' 3. Concurrently, against that single installation:
#'    * `R CMD check --install=check:<log>` for all static checks (DESCRIPTION,
#'      code, Rd/documentation, codoc, compiled code, install-log warnings ...),
#'    * the testthat suite, sharded over several processes,
#'    * the Rd examples, sharded over several processes,
#'    * every vignette in its own process.
#'
#' @param path Package source directory.
#' @param args Extra arguments for `R CMD check` (e.g. `"--as-cran"`).
#' @param build_args Extra arguments for `R CMD build`.
#' @param jobs Total parallelism (compile jobs and concurrent R processes).
#' @param profile Compiler profile, see [accel_env()].
#' @param cache_dir Persistent cache directory (compiler caches, cargo
#'   target dirs, test timings). Cache it in CI.
#' @param check_dir Where to put logs and results; a temp dir by default.
#' @param tests,examples,vignettes Run these parts of the check.
#' @param manual Build and check the PDF manual (needs LaTeX; slow).
#' @param error_on Signal an R error if a problem of at least this severity
#'   is found.
#' @param timeout Per-process timeout in seconds.
#' @param env Extra environment variables for every child process.
#' @param quiet Suppress progress messages.
#' @return An object of class `fastcheck`.
#' @export
fastcheck <- function(
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
) {
  profile <- match.arg(profile)
  error_on <- match.arg(error_on)
  t_start <- Sys.time()
  say <- function(...) if (!quiet) message(...)

  path <- normalizePath(path, mustWork = TRUE)
  desc <- read.dcf(file.path(path, "DESCRIPTION"))[1, ]
  pkg <- unname(desc["Package"])
  version <- unname(desc["Version"])

  if (is.null(check_dir)) {
    check_dir <- tempfile("fastcheck-")
  }
  dir.create(check_dir, recursive = TRUE, showWarnings = FALSE)
  check_dir <- normalizePath(check_dir)
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  cache_dir <- normalizePath(cache_dir)
  lib <- file.path(check_dir, "lib")
  dir.create(lib, showWarnings = FALSE)

  # Before the future file timestamps check, --as-cran asks up to three
  # internet time servers for the current time, one after another; on a
  # firewalled or offline runner that waits up to a minute and then only gives
  # "NOTE: unable to verify current time". Compare file times against the
  # system clock instead (the timestamp check itself still runs), unless the
  # caller asked for the online check.
  if (
    !"_R_CHECK_SYSTEM_CLOCK_" %in% names(env) &&
      !nzchar(Sys.getenv("_R_CHECK_SYSTEM_CLOCK_"))
  ) {
    env <- c(env, `_R_CHECK_SYSTEM_CLOCK_` = "FALSE")
  }
  r_libs <- paste(c(lib, .libPaths()), collapse = .Platform$path.sep)
  base_env <- c(env, R_LIBS = r_libs)
  timings <- list()
  entries <- list()
  result <- function() {
    make_result(pkg, version, entries, timings, check_dir, t_start, error_on)
  }

  say(sprintf(
    "\u2500\u2500 fastrcmdcheck %s %s (%d jobs, %s profile)",
    pkg,
    version,
    jobs,
    profile
  ))

  # -- 1. build ---------------------------------------------------------------
  say("\u2219 building source tarball")
  t0 <- Sys.time()
  build_log <- file.path(check_dir, "00build.log")
  b <- processx::run(
    rcmd(),
    c(
      "CMD",
      "build",
      "--no-build-vignettes",
      "--no-manual",
      build_args,
      build_source(path, check_dir)
    ),
    wd = check_dir,
    env = c("current", base_env),
    error_on_status = FALSE,
    stderr_to_stdout = TRUE
  )
  writeLines(b$stdout, build_log)
  timings$build <- secs(t0)
  tarball <- file.path(check_dir, sprintf("%s_%s.tar.gz", pkg, version))
  if (b$status != 0 || !file.exists(tarball)) {
    entries$build <- entry(
      "checking whether package can be built",
      "ERROR",
      tail_lines(b$stdout)
    )
    return(finish(result(), quiet))
  }

  # -- 2. single accelerated install ---------------------------------------------
  say("\u2219 compiling and installing (once)")
  t0 <- Sys.time()
  accel <- accel_env(cache_dir, jobs = jobs, profile = profile)
  stage <- stage_sources(tarball, pkg, cache_dir)
  install_log <- file.path(check_dir, "00install.out")
  inst <- processx::run(
    rcmd(),
    c(
      "CMD",
      "INSTALL",
      paste0("--library=", lib),
      "--no-multiarch",
      "--no-html",
      stage
    ),
    wd = check_dir,
    # symbol tables feed the 'checking compiled code' check
    env = c(
      "current",
      base_env,
      accel,
      `_R_SHLIB_BUILD_OBJECTS_SYMBOL_TABLES_` = "TRUE"
    ),
    error_on_status = FALSE,
    stderr_to_stdout = TRUE
  )
  writeLines(inst$stdout, install_log)
  save_cargo_targets(stage, pkg, cache_dir)
  timings$install <- secs(t0)
  if (inst$status != 0) {
    entries$install <- entry(
      sprintf(
        "checking whether package %s can be installed",
        sQuote(pkg, FALSE)
      ),
      "ERROR",
      tail_lines(inst$stdout, 40)
    )
    return(finish(result(), quiet))
  }

  # -- 3. everything else, concurrently ------------------------------------------
  run_donttest <- any(c("--as-cran", "--run-donttest") %in% args)
  test_plan <- if (tests) {
    plan_tests(stage, pkg, check_dir, cache_dir, jobs)
  } else {
    NULL
  }
  ex_plan <- if (examples) {
    plan_examples(pkg, lib, check_dir, jobs, run_donttest)
  } else {
    NULL
  }
  vig_plan <- if (vignettes) plan_vignettes(stage, desc, check_dir) else NULL

  check_args <- c(
    "CMD",
    "check",
    paste0("--install=check:", install_log),
    paste0("--library=", lib),
    "--no-build-vignettes",
    "--ignore-vignettes",
    "--no-tests",
    "--no-examples",
    if (!manual) "--no-manual",
    args,
    tarball
  )
  jobs_list <- c(
    list(list(
      id = "R CMD check (static)",
      kind = "static",
      command = rcmd(),
      args = check_args,
      wd = check_dir,
      env = base_env,
      log = file.path(check_dir, "00static.log"),
      weight = Inf
    )),
    test_plan$jobs,
    ex_plan$jobs,
    vig_plan$jobs
  )
  # Many processes run side by side: keep BLAS/OpenMP from oversubscribing.
  threads <- as.character(max(1L, parallel::detectCores() %/% jobs))
  thread_env <- c(
    OMP_NUM_THREADS = threads,
    OPENBLAS_NUM_THREADS = threads,
    MKL_NUM_THREADS = threads
  )
  thread_env <- thread_env[!nzchar(Sys.getenv(names(thread_env)))]
  for (i in seq_along(jobs_list)) {
    jobs_list[[i]]$env <- c(
      base_env,
      thread_env,
      jobs_list[[i]]$env,
      if (i > 1) c(`_R_CHECK_PACKAGE_NAME_` = pkg)
    )
  }

  say(sprintf(
    "\u2219 running %d processes on %d workers",
    length(jobs_list),
    jobs
  ))
  t0 <- Sys.time()
  res <- run_pool(
    jobs_list,
    workers = jobs,
    timeout = timeout,
    progress = !quiet
  )
  timings$checks <- secs(t0)

  # -- 4. collect -------------------------------------------------------------------
  static_log <- file.path(check_dir, paste0(pkg, ".Rcheck"), "00check.log")
  static <- if (file.exists(static_log)) parse_check_log(static_log) else NULL
  if (is.null(static) || !nrow(static)) {
    entries$static <- entry(
      "checking R CMD check (static checks)",
      "ERROR",
      tail_lines(readLines(file.path(check_dir, "00static.log"), warn = FALSE))
    )
  } else {
    static <- drop_build_artifacts(static)
    for (i in seq_len(nrow(static))) {
      entries[[paste0("static", i)]] <- entry(
        static$check[i],
        static$status[i],
        static$details[i]
      )
    }
  }
  if (!is.null(test_plan)) {
    entries$tests <- collect_tests(test_plan, res, cache_dir, pkg)
  }
  if (!is.null(ex_plan)) {
    entries$examples <- collect_examples(ex_plan, res)
  }
  if (!is.null(vig_plan)) {
    entries$vignettes <- collect_vignettes(vig_plan, res)
  }
  entries <- Filter(Negate(is.null), entries)

  finish(result(), quiet)
}

# A source tree that was itself unpacked from a built tarball (e.g. a CRAN
# release) ships build/vignette.rds, and R CMD build --no-build-vignettes then
# fails because the listed inst/doc outputs are absent. Build such trees from a
# scratch copy without that file, leaving the user's sources untouched.
build_source <- function(path, check_dir) {
  if (!file.exists(file.path(path, "build", "vignette.rds"))) {
    return(path)
  }
  copy <- file.path(check_dir, "00source", basename(normalizePath(path)))
  unlink(dirname(copy), recursive = TRUE)
  dir.create(copy, recursive = TRUE)
  files <- list.files(path, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  file.copy(
    files[basename(files) != ".git"],
    copy,
    recursive = TRUE,
    copy.date = TRUE
  )
  unlink(file.path(copy, "build", "vignette.rds"))
  copy
}

# The tarball is built with --no-build-vignettes (vignettes are re-built in
# their own shard instead), which makes --as-cran's incoming check complain
# about the missing vignette index. Remove exactly that message; if only the
# informational Maintainer line is left, the check is OK as it would be after a
# normal build.
drop_build_artifacts <- function(static) {
  i <- which(static$check == "checking CRAN incoming feasibility")
  if (!length(i)) {
    return(static)
  }
  i <- i[1]
  lines <- strsplit(static$details[i], "\n")[[1]]
  art <- grepl(
    "^Package has a VignetteBuilder field but no prebuilt vignette index",
    lines
  )
  if (!any(art)) {
    return(static)
  }
  lines <- lines[!art]
  rest <- lines[nzchar(trimws(lines))]
  static$details[i] <- paste(sub("\n+$", "", paste(lines, collapse = "\n")))
  if (static$status[i] == "NOTE" && all(startsWith(rest, "Maintainer:"))) {
    static$status[i] <- "OK"
  }
  static
}

default_jobs <- function() {
  n <- suppressWarnings(as.integer(Sys.getenv("FASTCHECK_JOBS")))
  if (is.na(n)) {
    n <- parallel::detectCores(logical = TRUE)
  }
  max(1L, n)
}

default_cache_dir <- function() {
  Sys.getenv(
    "FASTCHECK_CACHE_DIR",
    file.path(tools::R_user_dir("fastrcmdcheck", "cache"))
  )
}

secs <- function(t0) {
  round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
}

tail_lines <- function(x, n = 25) {
  x <- unlist(strsplit(paste(x, collapse = "\n"), "\n"))
  paste(utils::tail(x, n), collapse = "\n")
}

entry <- function(check, status, details = "") {
  list(check = check, status = status, details = details %||% "")
}

runner <- function(name) {
  system.file("runners", name, package = "fastrcmdcheck", mustWork = TRUE)
}

# -- staging & cargo target persistence ---------------------------------------

stage_sources <- function(tarball, pkg, cache_dir) {
  root <- file.path(cache_dir, "stage")
  dir.create(root, showWarnings = FALSE)
  stage <- file.path(root, pkg)
  unlink(stage, recursive = TRUE, force = TRUE)
  utils::untar(tarball, exdir = root)
  restore_cargo_targets(stage, pkg, cache_dir)
  stage
}

cargo_dirs <- function(stage) {
  src <- file.path(stage, "src")
  if (!dir.exists(src)) {
    return(character())
  }
  tomls <- list.files(
    src,
    pattern = "^Cargo\\.toml$",
    recursive = TRUE,
    full.names = TRUE
  )
  # skip manifests of vendored dependency crates
  tomls <- tomls[!grepl("/(vendor|target)/", tomls)]
  dirname(tomls)
}

cargo_cache <- function(stage, dir, pkg, cache_dir) {
  rel <- substring(dir, nchar(stage) + 2L)
  file.path(cache_dir, "cargo-target", pkg, rel, "target")
}

restore_cargo_targets <- function(stage, pkg, cache_dir) {
  for (d in cargo_dirs(stage)) {
    saved <- cargo_cache(stage, d, pkg, cache_dir)
    tgt <- file.path(d, "target")
    if (dir.exists(saved) && !dir.exists(tgt)) {
      file.rename(saved, tgt)
      drop_cargo_outputs(tgt)
    }
  }
}

# Makevars rules like `$(STATLIB): ; cargo build` have no prerequisites, so a
# restored librustpkg.a would never be rebuilt: stale Rust code gets linked and
# R's "checking Rust compilation" is skipped. Removing the final artifacts in
# target/[<triple>/]<profile>/ forces make to call cargo, which still reuses
# the cached deps/, build/ and incremental state.
drop_cargo_outputs <- function(tgt) {
  dirs <- list.dirs(tgt, recursive = FALSE)
  dirs <- c(dirs, list.dirs(dirs, recursive = FALSE))
  # profile dirs (release/, <triple>/debug/, ...) carry cargo's .fingerprint/
  profiles <- dirs[dir.exists(file.path(dirs, ".fingerprint"))]
  for (p in profiles) {
    f <- list.files(p, all.files = TRUE, no.. = TRUE, full.names = TRUE)
    unlink(f[!dir.exists(f)])
  }
}

save_cargo_targets <- function(stage, pkg, cache_dir) {
  for (d in cargo_dirs(stage)) {
    tgt <- file.path(d, "target")
    if (!dir.exists(tgt)) {
      next
    }
    saved <- cargo_cache(stage, d, pkg, cache_dir)
    unlink(saved, recursive = TRUE)
    dir.create(dirname(saved), recursive = TRUE, showWarnings = FALSE)
    file.rename(tgt, saved)
  }
}

# -- tests --------------------------------------------------------------------

plan_tests <- function(stage, pkg, check_dir, cache_dir, jobs) {
  tdir <- file.path(stage, "tests")
  if (!dir.exists(tdir)) {
    return(NULL)
  }
  drivers <- list.files(tdir, pattern = "\\.[rR]$")
  jobs_list <- list()

  ttdir <- file.path(tdir, "testthat")
  is_tt <- function(f) {
    any(grepl("test_check\\s*\\(", readLines(file.path(tdir, f), warn = FALSE)))
  }
  tt_driver <- Filter(is_tt, drivers)
  shards <- list()
  if (length(tt_driver) && dir.exists(ttdir)) {
    files <- list.files(ttdir, pattern = "^test.*\\.[rR]$")
    hist <- read_timings(cache_dir, pkg)
    w <- vapply(
      files,
      function(f) {
        if (!is.na(hist[f])) {
          hist[[f]]
        } else {
          file.size(file.path(ttdir, f)) / 2000
        }
      },
      0
    )
    shards <- lpt(files, w, min(length(files), jobs))
    for (i in seq_along(shards)) {
      priv <- file.path(check_dir, "tests", sprintf("shard-%02d", i))
      dir.create(priv, recursive = TRUE, showWarnings = FALSE)
      file.copy(tdir, priv, recursive = TRUE, copy.date = TRUE)
      unlink(file.path(priv, "tests", "testthat", setdiff(files, shards[[i]])))
      jobs_list[[length(jobs_list) + 1]] <- list(
        id = sprintf("tests shard %d/%d", i, length(shards)),
        kind = "testthat",
        command = rscript(),
        args = c(
          "--no-echo",
          "--no-restore",
          runner("testthat.R"),
          pkg,
          file.path(priv, "tests", "testthat"),
          file.path(priv, "result.rds")
        ),
        wd = file.path(priv, "tests"),
        log = file.path(priv, "testthat.Rout"),
        weight = sum(w[shards[[i]]]),
        meta = list(files = shards[[i]], result = file.path(priv, "result.rds"))
      )
    }
  }

  # Non-testthat test scripts run exactly as R CMD check runs them.
  for (f in setdiff(drivers, tt_driver)) {
    priv <- file.path(check_dir, "tests", paste0("plain-", f))
    dir.create(priv, recursive = TRUE, showWarnings = FALSE)
    file.copy(tdir, priv, recursive = TRUE, copy.date = TRUE)
    wd <- file.path(priv, "tests")
    jobs_list[[length(jobs_list) + 1]] <- list(
      id = paste("tests", f),
      kind = "plain-test",
      command = rcmd(),
      args = c("CMD", "BATCH", "--vanilla", "--no-timing", f, paste0(f, "out")),
      wd = wd,
      log = file.path(priv, "batch.log"),
      weight = 1e3,
      meta = list(
        file = f,
        rout = file.path(wd, paste0(f, "out")),
        save = file.path(tdir, paste0(f, "out.save"))
      )
    )
  }
  if (!length(jobs_list)) {
    return(NULL)
  }
  list(jobs = jobs_list)
}

lpt <- function(items, weights, k) {
  bins <- vector("list", k)
  load <- numeric(k)
  for (i in order(-weights)) {
    b <- which.min(load)
    bins[[b]] <- c(bins[[b]], items[i])
    load[b] <- load[b] + weights[i]
  }
  bins[lengths(bins) > 0]
}

timings_file <- function(cache_dir, pkg) {
  file.path(cache_dir, "timings", paste0(pkg, ".rds"))
}

read_timings <- function(cache_dir, pkg) {
  f <- timings_file(cache_dir, pkg)
  if (file.exists(f)) {
    tryCatch(readRDS(f), error = function(e) numeric())
  } else {
    numeric()
  }
}

collect_tests <- function(plan, res, cache_dir, pkg) {
  problems <- character()
  per_file <- numeric()
  n_tests <- 0
  for (j in plan$jobs) {
    r <- res[[j$id]]
    if (j$kind == "testthat") {
      out <- if (file.exists(j$meta$result)) readRDS(j$meta$result) else NULL
      df <- out$results
      if (!is.null(df) && nrow(df)) {
        n_tests <- n_tests + nrow(df)
        agg <- tapply(df$real, df$file, sum)
        per_file[names(agg)] <- agg
        bad <- df[df$failed > 0 | df$error, , drop = FALSE]
        if (nrow(bad)) {
          problems <- c(
            problems,
            sprintf("  [%s] %s: %s", j$id, bad$file, bad$test)
          )
        }
      }
      if (
        !identical(r$status, 0L) &&
          (is.null(df) || !nrow(df[df$failed > 0 | df$error, , drop = FALSE]))
      ) {
        problems <- c(
          problems,
          sprintf(
            "  [%s] %s",
            j$id,
            if (isTRUE(r$timed_out)) {
              "timed out"
            } else {
              out$error %||% "test process failed"
            }
          )
        )
      }
      if (length(problems)) {
        problems <- c(
          problems,
          paste0("  log: ", r$log),
          indent(tail_lines(readLines(r$log, warn = FALSE), 30))
        )
      }
    } else {
      if (!identical(r$status, 0L)) {
        rout <- if (file.exists(j$meta$rout)) {
          readLines(j$meta$rout, warn = FALSE)
        } else {
          ""
        }
        problems <- c(
          problems,
          sprintf("  Running %s failed", sQuote(j$meta$file, FALSE)),
          indent(tail_lines(rout, 20))
        )
      } else if (file.exists(j$meta$save)) {
        d <- utils::capture.output(tools::Rdiff(j$meta$rout, j$meta$save))
        if (length(d) > 1) {
          problems <- c(
            problems,
            sprintf(
              "  Differences for %s vs .Rout.save (informational):",
              j$meta$file
            ),
            indent(paste(d, collapse = "\n"))
          )
        }
      }
    }
  }
  if (length(per_file)) {
    dir.create(
      dirname(timings_file(cache_dir, pkg)),
      recursive = TRUE,
      showWarnings = FALSE
    )
    old <- read_timings(cache_dir, pkg)
    old[names(per_file)] <- per_file
    saveRDS(old, timings_file(cache_dir, pkg))
  }
  failed <- any(vapply(
    plan$jobs,
    function(j) !identical(res[[j$id]]$status, 0L),
    TRUE
  ))
  entry(
    sprintf(
      "checking tests (%d processes, %d testthat expectations blocks)",
      length(plan$jobs),
      n_tests
    ),
    if (failed) "ERROR" else "OK",
    paste(problems, collapse = "\n")
  )
}

indent <- function(x, by = "    ") {
  paste0(by, strsplit(paste(x, collapse = "\n"), "\n")[[1]], collapse = "\n")
}

# -- examples -------------------------------------------------------------------

plan_examples <- function(pkg, lib, check_dir, jobs, run_donttest) {
  db <- tools::Rd_db(pkg, lib.loc = lib)
  if (!length(db)) {
    return(NULL)
  }
  exdir <- file.path(check_dir, "examples")
  dir.create(exdir, showWarnings = FALSE)
  files <- character()
  for (nm in names(db)) {
    out <- file.path(exdir, paste0(sub("\\.Rd$", "", basename(nm)), ".R"))
    tools::Rd2ex(
      db[[nm]],
      out,
      commentDontrun = TRUE,
      commentDonttest = !run_donttest
    )
    if (file.exists(out)) files <- c(files, out)
  }
  if (!length(files)) {
    return(NULL)
  }
  w <- file.size(files)
  k <- max(1L, min(jobs, ceiling(length(files) / 4)))
  # Within a shard, keep R CMD check's (sorted) topic order: examples can leave
  # files behind that a later topic would trip over (fs: file_chmod creates
  # ./bar, which create's dir_create("bar") then fails on).
  shards <- lapply(lpt(files, w, k), sort, method = "radix")
  jobs_list <- lapply(seq_along(shards), function(i) {
    rds <- file.path(exdir, sprintf("result-%02d.rds", i))
    # Examples write to relative paths (e.g. fs creates ./bar); concurrent
    # shards sharing a directory would trip over each other's files.
    wd <- file.path(exdir, sprintf("shard-%02d", i))
    dir.create(wd, showWarnings = FALSE)
    list(
      id = sprintf("examples shard %d/%d", i, length(shards)),
      kind = "examples",
      command = rscript(),
      args = c(
        "--no-echo",
        "--no-restore",
        runner("examples.R"),
        pkg,
        rds,
        shards[[i]]
      ),
      wd = wd,
      log = file.path(exdir, sprintf("examples-%02d.Rout", i)),
      weight = sum(file.size(shards[[i]])),
      meta = list(result = rds)
    )
  })
  list(jobs = jobs_list, n = length(files))
}

collect_examples <- function(plan, res) {
  problems <- character()
  for (j in plan$jobs) {
    r <- res[[j$id]]
    out <- if (file.exists(j$meta$result)) readRDS(j$meta$result) else NULL
    if (length(out$failed)) {
      problems <- c(
        problems,
        sprintf(
          "  Running examples in %s failed: %s",
          sQuote(names(out$failed), FALSE),
          out$failed
        ),
        paste0("  log: ", r$log)
      )
    } else if (!identical(r$status, 0L)) {
      problems <- c(
        problems,
        sprintf(
          "  [%s] %s",
          j$id,
          if (isTRUE(r$timed_out)) "timed out" else "process failed"
        ),
        indent(tail_lines(readLines(r$log, warn = FALSE), 30))
      )
    }
  }
  entry(
    sprintf(
      "checking examples (%d topics, %d processes)",
      plan$n,
      length(plan$jobs)
    ),
    if (length(problems)) "ERROR" else "OK",
    paste(problems, collapse = "\n")
  )
}

# -- vignettes ----------------------------------------------------------------------

plan_vignettes <- function(stage, desc, check_dir) {
  v <- tools::pkgVignettes(dir = stage, check = FALSE)
  if (is.null(v) || !length(v$docs)) {
    return(NULL)
  }
  builders <- if (!is.na(desc["VignetteBuilder"])) {
    trimws(strsplit(desc[["VignetteBuilder"]], ",")[[1]])
  } else {
    character()
  }
  jobs_list <- lapply(v$docs, function(doc) {
    name <- basename(doc)
    priv <- file.path(check_dir, "vignettes", tools::file_path_sans_ext(name))
    dir.create(priv, recursive = TRUE, showWarnings = FALSE)
    file.copy(
      list.files(
        dirname(doc),
        full.names = TRUE,
        all.files = TRUE,
        no.. = TRUE
      ),
      priv,
      recursive = TRUE,
      copy.date = TRUE
    )
    list(
      id = paste("vignette", name),
      kind = "vignette",
      command = rscript(),
      args = c(
        "--no-echo",
        "--no-restore",
        runner("vignette.R"),
        file.path(priv, name),
        paste(builders, collapse = ",")
      ),
      wd = priv,
      log = file.path(priv, "build.log"),
      weight = 1e6 + file.size(doc)
    )
  })
  list(jobs = jobs_list)
}

collect_vignettes <- function(plan, res) {
  problems <- character()
  for (j in plan$jobs) {
    r <- res[[j$id]]
    if (!identical(r$status, 0L)) {
      problems <- c(
        problems,
        sprintf(
          "  %s: %s",
          j$id,
          if (isTRUE(r$timed_out)) "timed out" else "failed"
        ),
        indent(tail_lines(readLines(r$log, warn = FALSE), 30))
      )
    }
  }
  entry(
    sprintf(
      "checking re-building of vignette outputs (%d vignettes)",
      length(plan$jobs)
    ),
    if (length(problems)) "ERROR" else "OK",
    paste(problems, collapse = "\n")
  )
}

# -- result -----------------------------------------------------------------------

make_result <- function(
  pkg,
  version,
  entries,
  timings,
  check_dir,
  t_start,
  error_on
) {
  df <- data.frame(
    check = vapply(entries, `[[`, "", "check"),
    status = vapply(entries, `[[`, "", "status"),
    details = vapply(entries, `[[`, "", "details"),
    stringsAsFactors = FALSE
  )
  rownames(df) <- NULL
  pick <- function(s) {
    d <- df[df$status == s, , drop = FALSE]
    if (!nrow(d)) {
      return(character())
    }
    paste0(
      d$check,
      " ... ",
      s,
      ifelse(nzchar(d$details), paste0("\n", d$details), "")
    )
  }
  timings$total <- secs(t_start)
  structure(
    list(
      package = pkg,
      version = version,
      errors = pick("ERROR"),
      warnings = pick("WARNING"),
      notes = pick("NOTE"),
      checks = df,
      timings = timings,
      check_dir = check_dir,
      error_on = error_on
    ),
    class = "fastcheck"
  )
}

finish <- function(x, quiet) {
  if (!quiet) {
    print(x)
  }
  thr <- switch(x$error_on, never = 0, error = 1, warning = 2, note = 3)
  n <- c(length(x$errors), length(x$warnings), length(x$notes))
  if (any(n[seq_len(thr)] > 0)) {
    stop(
      sprintf(
        "R CMD check found %d error(s), %d warning(s), %d note(s)",
        n[1],
        n[2],
        n[3]
      ),
      call. = FALSE
    )
  }
  invisible(x)
}

#' @export
print.fastcheck <- function(x, ...) {
  cat("\n")
  for (s in c("errors", "warnings", "notes")) {
    for (e in x[[s]]) {
      cat("\u276f ", e, "\n\n", sep = "")
    }
  }
  n <- c(length(x$errors), length(x$warnings), length(x$notes))
  mk <- function(k, lab) {
    sprintf(
      "%d %s%s %s",
      k,
      lab,
      if (k == 1) "" else "s",
      if (k) "\u2716" else "\u2714"
    )
  }
  t <- x$timings
  cat(sprintf(
    "\u2500\u2500 %s %s \u2500\u2500 Duration: %.1fs (build %.1fs, install %.1fs, checks %.1fs)\n",
    x$package,
    x$version,
    t$total %||% NA,
    t$build %||% 0,
    t$install %||% 0,
    t$checks %||% 0
  ))
  cat(
    mk(n[1], "error"),
    " | ",
    mk(n[2], "warning"),
    " | ",
    mk(n[3], "note"),
    "\n",
    sep = ""
  )
  cat("Logs: ", x$check_dir, "\n", sep = "")
  invisible(x)
}
