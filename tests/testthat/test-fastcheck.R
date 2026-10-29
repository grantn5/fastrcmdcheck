desc <- function(pkg) {
  c(
    paste("Package:", pkg),
    "Title: Test Package",
    "Version: 0.0.1",
    "Authors@R: person(\"A\", \"B\", email = \"a@b.org\", role = c(\"aut\", \"cre\"))",
    "Description: A small package used in tests of the check runner.",
    "License: GPL-3",
    "Encoding: UTF-8",
    "Suggests: testthat (>= 3.0.0)",
    "Config/testthat/edition: 3"
  )
}

rd <- function(name, example) {
  c(
    sprintf("\\name{%s}", name),
    sprintf("\\alias{%s}", name),
    "\\title{F}",
    sprintf("\\usage{%s(x)}", name),
    "\\arguments{\\item{x}{x}}",
    "\\value{x}",
    "\\description{F.}",
    "\\examples{",
    example,
    "}"
  )
}

test_that("a clean package passes and failures in every shard are reported", {
  skip_on_cran()
  ok <- fixture_pkg(
    "fcok",
    list(
      DESCRIPTION = desc("fcok"),
      NAMESPACE = "export(f)",
      "R/f.R" = "f <- function(x) x + 1",
      "man/f.Rd" = rd("f", "f(1)"),
      "tests/testthat.R" = c(
        "library(testthat)",
        "library(fcok)",
        "test_check(\"fcok\")"
      ),
      "tests/testthat/test-a.R" = "test_that('a', expect_equal(f(1), 2))",
      "tests/testthat/test-b.R" = "test_that('b', expect_equal(f(2), 3))"
    )
  )
  cache <- tempdir_new()
  res <- fastcheck(ok, jobs = 2, cache_dir = cache, quiet = TRUE)
  expect_length(res$errors, 0)
  expect_length(res$warnings, 0)
  expect_true(any(grepl("^checking tests", res$checks$check)))
  expect_true(file.exists(file.path(cache, "timings", "fcok.rds")))

  bad <- fixture_pkg(
    "fcbad",
    list(
      DESCRIPTION = desc("fcbad"),
      NAMESPACE = "export(f)",
      "R/f.R" = "f <- function(x) x + 1",
      "man/f.Rd" = rd("f", "stop('example boom')"),
      "tests/testthat.R" = c(
        "library(testthat)",
        "library(fcbad)",
        "test_check(\"fcbad\")"
      ),
      "tests/testthat/test-a.R" = "test_that('a', expect_equal(f(1), 2))",
      "tests/testthat/test-b.R" = "test_that('b fails', expect_equal(f(2), 99))"
    )
  )
  res <- fastcheck(bad, jobs = 2, cache_dir = cache, quiet = TRUE)
  expect_true(any(grepl("checking tests.*ERROR", res$errors)))
  expect_true(any(grepl("b fails", res$errors)))
  expect_true(any(grepl("example boom", res$errors)))
  expect_error(
    fastcheck(
      bad,
      jobs = 2,
      cache_dir = cache,
      quiet = TRUE,
      error_on = "error"
    ),
    "error"
  )
})

test_that("install failures stop early with an ERROR", {
  skip_on_cran()
  p <- fixture_pkg(
    "fcbroken",
    list(
      DESCRIPTION = desc("fcbroken"),
      NAMESPACE = "useDynLib(fcbroken)",
      "src/x.c" = "this is not C;"
    )
  )
  res <- fastcheck(p, jobs = 2, cache_dir = tempdir_new(), quiet = TRUE)
  expect_length(res$errors, 1)
  expect_match(res$errors, "can be installed")
})

test_that("future file timestamps are checked against the system clock", {
  skip_on_cran()
  old <- Sys.getenv("_R_CHECK_SYSTEM_CLOCK_", NA)
  Sys.unsetenv("_R_CHECK_SYSTEM_CLOCK_")
  on.exit(if (!is.na(old)) Sys.setenv(`_R_CHECK_SYSTEM_CLOCK_` = old))
  p <- fixture_pkg(
    "fcclock",
    list(
      DESCRIPTION = desc("fcclock"),
      NAMESPACE = "export(f)",
      "R/f.R" = "f <- function(x) x + 1",
      "man/f.Rd" = rd("f", "f(1)")
    )
  )
  res <- fastcheck(
    p,
    jobs = 2,
    cache_dir = tempdir_new(),
    quiet = TRUE,
    tests = FALSE,
    examples = FALSE,
    vignettes = FALSE,
    env = c(`_R_CHECK_FUTURE_FILE_TIMESTAMPS_` = "TRUE")
  )
  ts <- res$checks[res$checks$check == "checking for future file timestamps", ]
  expect_equal(ts$status, "OK")
  expect_lt(res$timings$checks, 30)
})

test_that("examples run in R CMD check's topic order", {
  skip_on_cran()
  # zz is the larger topic, so load balancing would run it first; it leaves
  # ./bar behind, which breaks aa if aa does not run before it, as in R.
  p <- fixture_pkg(
    "fcorder",
    list(
      DESCRIPTION = desc("fcorder"),
      NAMESPACE = "export(aa, zz)",
      "R/f.R" = c("aa <- function(x) x", "zz <- function(x) x"),
      "man/aa.Rd" = rd("aa", "stopifnot(dir.create('bar'))"),
      "man/zz.Rd" = rd("zz", c(rep("aa(1)", 50), "file.create('bar')"))
    )
  )
  res <- fastcheck(
    p,
    jobs = 2,
    cache_dir = tempdir_new(),
    quiet = TRUE,
    tests = FALSE,
    vignettes = FALSE
  )
  expect_false(any(grepl("checking examples", res$errors)))
})
