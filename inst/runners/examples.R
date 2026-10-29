# Run a batch of extracted Rd examples against the installed package,
# mimicking R CMD check (fresh objects, RNG and options per topic, pdf device).
# Usage: Rscript examples.R <package> <result.rds> <example files...>
# Runner state lives in a local environment: the global environment is wiped
# between topics, like R CMD check's cleanEx().
local({
  args <- commandArgs(TRUE)
  pkg <- args[[1]]
  out <- args[[2]]
  files <- args[-(1:2)]

  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
  grDevices::pdf(file = tempfile(fileext = ".pdf"))
  options(warn = 1)
  base_opts <- options()

  failed <- character()
  timings <- numeric()
  for (f in files) {
    topic <- sub("\\.R$", "", basename(f))
    cat(sprintf("\n### ** Example: %s\n\n", topic))
    RNGkind("default", "default", "default")
    set.seed(1)
    env <- new.env(parent = globalenv())
    t0 <- proc.time()[["elapsed"]]
    err <- tryCatch(
      {
        source(
          f,
          local = env,
          echo = TRUE,
          max.deparse.length = Inf,
          spaced = FALSE,
          encoding = "UTF-8"
        )
        NULL
      },
      error = function(e) conditionMessage(e)
    )
    timings[topic] <- proc.time()[["elapsed"]] - t0
    if (!is.null(err)) {
      cat(sprintf("\nError in example '%s': %s\n", topic, err))
      failed[topic] <- err
    }
    rm(list = ls(globalenv(), all.names = TRUE), envir = globalenv())
    options(base_opts[setdiff(names(base_opts), "warn")])
    while (grDevices::dev.cur() > 1L) {
      grDevices::dev.off()
    }
    grDevices::pdf(file = tempfile(fileext = ".pdf"))
  }

  saveRDS(list(failed = failed, timings = timings), out)
  quit(status = if (length(failed)) 1L else 0L)
})
