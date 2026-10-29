# Compilation acceleration: parallel make, compiler caches and Rust/cargo
# settings. Everything here is expressed as environment variables plus one
# generated user Makevars file, so it applies to R CMD INSTALL and to any
# nested make/cmake/cargo invocations of the package's own build scripts.

#' Environment that accelerates compiling an R package
#'
#' @param cache_dir Directory holding the persistent caches (ccache, sccache).
#'   Persist it between CI runs (e.g. with `actions/cache`).
#' @param jobs Number of parallel compile jobs.
#' @param profile `"faithful"` keeps R's compiler flags untouched (results
#'   match a plain `R CMD check`). `"fast"` additionally compiles C/C++ with
#'   `-O0 -g0` and Rust without LTO at `opt-level=1`; much faster for heavy
#'   C++/Rust code but may hide optimisation-dependent compiler warnings.
#' @param ccache,sccache Use the compiler cache if it is on the `PATH`.
#' @return Named character vector of environment variables.
#' @export
accel_env <- function(
  cache_dir,
  jobs = parallel::detectCores(),
  profile = c("faithful", "fast"),
  ccache = TRUE,
  sccache = TRUE
) {
  profile <- match.arg(profile)
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  cache_dir <- normalizePath(cache_dir)
  jobs <- max(1L, as.integer(jobs))

  env <- c(
    MAKEFLAGS = paste0("-j", jobs),
    CMAKE_BUILD_PARALLEL_LEVEL = as.character(jobs),
    CARGO_BUILD_JOBS = as.character(jobs)
  )

  ccache_bin <- if (ccache) Sys.which("ccache") else ""
  if (nzchar(ccache_bin)) {
    env <- c(
      env,
      CCACHE_DIR = file.path(cache_dir, "ccache"),
      # Sources are staged under a stable path inside cache_dir; basedir makes
      # the cache hit even if cache_dir itself moves between CI runners.
      CCACHE_BASEDIR = cache_dir,
      CCACHE_NOHASHDIR = "true",
      CCACHE_SLOPPINESS = "include_file_mtime,include_file_ctime,time_macros",
      CCACHE_MAXSIZE = Sys.getenv("CCACHE_MAXSIZE", "5G")
    )
  }

  sccache_bin <- if (sccache) Sys.which("sccache") else ""
  if (nzchar(sccache_bin) && !nzchar(Sys.getenv("RUSTC_WRAPPER"))) {
    env <- c(
      env,
      RUSTC_WRAPPER = unname(sccache_bin),
      SCCACHE_DIR = Sys.getenv("SCCACHE_DIR", file.path(cache_dir, "sccache"))
    )
  }

  if (profile == "fast") {
    # Config-level profile overrides take precedence over Cargo.toml, so this
    # also neutralises `lto = true` / `codegen-units = 1` in package crates.
    env <- c(
      env,
      CARGO_PROFILE_RELEASE_LTO = "false",
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "256",
      CARGO_PROFILE_RELEASE_OPT_LEVEL = "1",
      CARGO_PROFILE_RELEASE_DEBUG = "false"
    )
    if (!"RUSTC_WRAPPER" %in% names(env)) {
      # Incremental compilation pays off with the persistent target dir, but
      # sccache refuses to cache incremental builds.
      env <- c(env, CARGO_PROFILE_RELEASE_INCREMENTAL = "true")
    }
  }

  makevars <- write_makevars(
    cache_dir,
    ccache = nzchar(ccache_bin),
    profile = profile
  )
  if (!is.null(makevars)) {
    env <- c(env, R_MAKEVARS_USER = makevars)
  }
  env
}

compiler_vars <- c("CC", "CXX", "CXX11", "CXX14", "CXX17", "CXX20", "CXX23")
flag_vars <- c(
  "CFLAGS",
  "CXXFLAGS",
  "CXX11FLAGS",
  "CXX14FLAGS",
  "CXX17FLAGS",
  "CXX20FLAGS",
  "CXX23FLAGS",
  "FFLAGS",
  "FCFLAGS"
)

write_makevars <- function(cache_dir, ccache, profile) {
  if (!ccache && profile == "faithful") {
    return(NULL)
  }
  conf <- read_makeconf()
  lines <- character()

  # Keep the user's own Makevars (only one user Makevars file is ever read).
  user <- tools::makevars_user()
  if (length(user) && nzchar(user)) {
    lines <- c(lines, paste("include", user))
    conf <- utils::modifyList(conf, as.list(read_make_assignments(user)))
  }

  if (ccache) {
    for (v in compiler_vars) {
      val <- conf[[v]]
      if (is.null(val) || !nzchar(val) || grepl("ccache", val, fixed = TRUE)) {
        next
      }
      lines <- c(lines, sprintf("%s = ccache %s", v, val))
    }
  }

  if (profile == "fast") {
    strip <- function(val) {
      val <- gsub(
        "(^|\\s)(-O[0-9sgz]*|-g[^ ]*|-D_FORTIFY_SOURCE=?[0-9]*|-flto[^ ]*)(?=\\s|$)",
        " ",
        val,
        perl = TRUE
      )
      trimws(gsub("\\s+", " ", val))
    }
    # Some toolchains (e.g. conda) put -O2 -D_FORTIFY_SOURCE in CPPFLAGS;
    # with -O0 the latter turns into a warning on every file.
    if (!is.null(conf$CPPFLAGS)) {
      lines <- c(lines, sprintf("CPPFLAGS = %s", strip(conf$CPPFLAGS)))
    }
    for (v in flag_vars) {
      if (is.null(conf[[v]])) {
        next
      }
      lines <- c(lines, sprintf("%s = %s -O0 -g0", v, strip(conf[[v]])))
    }
  }

  path <- file.path(cache_dir, sprintf("Makevars-%s", profile))
  old <- if (file.exists(path)) readLines(path, warn = FALSE) else NULL
  if (!identical(old, lines)) {
    writeLines(lines, path)
  }
  path
}

read_make_assignments <- function(path) {
  x <- readLines(path, warn = FALSE)
  # join continuation lines
  x <- strsplit(gsub("\\\\\n", " ", paste(x, collapse = "\n")), "\n")[[1]]
  m <- regmatches(x, regexec("^\\s*([A-Za-z0-9_]+)\\s*[:+]?=\\s*(.*)$", x))
  m <- m[lengths(m) == 3]
  stats::setNames(vapply(m, `[[`, "", 3), vapply(m, `[[`, "", 2))
}

read_makeconf <- function() {
  arch <- Sys.getenv("R_ARCH")
  vals <- read_make_assignments(file.path(R.home("etc"), arch, "Makeconf"))
  expand <- function(v, depth = 0) {
    if (depth > 10) {
      return(v)
    }
    refs <- regmatches(v, gregexpr("\\$\\(([A-Za-z0-9_]+)\\)", v))[[1]]
    for (r in unique(refs)) {
      name <- substr(r, 3, nchar(r) - 1)
      v <- gsub(
        r,
        expand(if (is.na(vals[name])) "" else vals[[name]], depth + 1),
        v,
        fixed = TRUE
      )
    }
    v
  }
  as.list(vapply(vals, expand, ""))
}
