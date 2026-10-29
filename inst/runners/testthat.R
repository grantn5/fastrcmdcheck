# Run one shard of a package's testthat suite against the installed package.
# Usage: Rscript testthat.R <package> <testthat dir> <result.rds>
# The orchestrator gives every shard a private copy of tests/ that only
# contains this shard's test files (helpers/setup files are kept), so shards
# cannot step on each other's working-directory files.
args <- commandArgs(TRUE)
pkg <- args[[1]]
test_dir <- args[[2]]
out <- args[[3]]

res <- tryCatch(
  testthat::test_dir(
    test_dir,
    package = pkg,
    load_package = "installed",
    reporter = testthat::ProgressReporter$new(show_praise = FALSE),
    stop_on_failure = FALSE
  ),
  error = function(e) e
)

if (inherits(res, "error")) {
  saveRDS(list(error = conditionMessage(res), results = NULL), out)
  message("Error running tests: ", conditionMessage(res))
  quit(status = 1)
}

df <- as.data.frame(res)
saveRDS(list(error = NULL, results = df), out)
bad <- sum(df$failed) + sum(df$error)
quit(status = if (bad > 0) 1L else 0L)
