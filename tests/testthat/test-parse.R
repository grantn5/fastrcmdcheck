test_that("parse_check_log extracts statuses and details", {
  log <- c(
    "* using log directory '/tmp/x.Rcheck'",
    "* checking for file 'x/DESCRIPTION' ... OK",
    "* checking top-level files ... NOTE",
    "Non-standard files/directories found at top level:",
    "  'bench'",
    "* checking whether package 'x' can be installed ... [12s/12s] WARNING",
    "Found the following significant warnings:",
    "  foo.c:1: warning: unused variable",
    "* checking tests ...",
    "  Running 'testthat.R'",
    " ERROR",
    "Running the tests in 'tests/testthat.R' failed.",
    "* DONE",
    "Status: 1 ERROR, 1 WARNING, 1 NOTE"
  )
  x <- parse_check_log(log)
  expect_equal(x$status, c("OK", "NOTE", "WARNING", "ERROR"))
  expect_equal(x$check[2], "checking top-level files")
  expect_equal(x$check[3], "checking whether package 'x' can be installed")
  expect_match(x$details[2], "Non-standard files")
  expect_match(x$details[4], "Running the tests")
  expect_false(grepl("^\\s*ERROR\\s*$", x$details[4]))
})

test_that("lpt balances shards", {
  bins <- fastrcmdcheck:::lpt(letters[1:6], c(10, 1, 1, 1, 1, 6), 2)
  expect_length(bins, 2)
  expect_setequal(unlist(bins), letters[1:6])
  w <- c(a = 10, b = 1, c = 1, d = 1, e = 1, f = 6)
  loads <- vapply(bins, function(b) sum(w[b]), 0)
  expect_equal(sort(loads), c(10, 10))
})

test_that("lpt never returns empty shards", {
  bins <- fastrcmdcheck:::lpt(c("a", "b"), c(1, 1), 2)
  expect_true(all(lengths(bins) > 0))
})

test_that("accel_env sets parallelism and writes a ccache Makevars", {
  skip_if(Sys.which("ccache") == "")
  d <- tempdir_new()
  env <- accel_env(d, jobs = 3, profile = "fast", sccache = FALSE)
  expect_equal(env[["MAKEFLAGS"]], "-j3")
  expect_equal(env[["CARGO_PROFILE_RELEASE_LTO"]], "false")
  mv <- readLines(env[["R_MAKEVARS_USER"]])
  expect_true(any(grepl("^CXX17 = ccache ", mv)))
  expect_true(any(grepl("^CXXFLAGS = .* -O0 -g0$", mv)))
  expect_false(any(grepl("-O2", mv[grepl("^CXXFLAGS", mv)])))
})

test_that("faithful profile leaves compiler flags alone", {
  d <- tempdir_new()
  env <- accel_env(
    d,
    jobs = 2,
    profile = "faithful",
    ccache = FALSE,
    sccache = FALSE
  )
  expect_false("R_MAKEVARS_USER" %in% names(env))
  expect_false(any(startsWith(names(env), "CARGO_PROFILE")))
})

test_that("the no-vignette-index artifact of the fast build is dropped", {
  static <- data.frame(
    check = c(
      "checking CRAN incoming feasibility",
      "checking CRAN incoming feasibility"
    ),
    status = c("NOTE", "NOTE"),
    details = c(
      "Maintainer: 'A B <a@b.org>'\n\nPackage has a VignetteBuilder field but no prebuilt vignette index.",
      "Maintainer: 'A B <a@b.org>'\n\nNew submission"
    ),
    stringsAsFactors = FALSE
  )
  out <- fastrcmdcheck:::drop_build_artifacts(static[1, ])
  expect_equal(out$status, "OK")
  expect_false(grepl("vignette index", out$details))
  # genuine notes are kept
  expect_equal(fastrcmdcheck:::drop_build_artifacts(static[2, ])$status, "NOTE")
})
