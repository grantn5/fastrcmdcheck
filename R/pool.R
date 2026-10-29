# Minimal process pool on top of processx. A job is a list with
# id, command, args, wd, env (named chr), log (stdout+stderr file) and an
# optional `weight` (larger jobs are started first).

run_pool <- function(jobs, workers, timeout = Inf, progress = TRUE) {
  if (!length(jobs)) {
    return(list())
  }
  weights <- vapply(jobs, function(j) as.numeric(j$weight %||% 0), 0)
  queue <- jobs[order(-weights)]
  running <- list()
  results <- list()
  t0 <- Sys.time()

  start <- function(job) {
    dir.create(dirname(job$log), recursive = TRUE, showWarnings = FALSE)
    job$proc <- processx::process$new(
      job$command,
      job$args,
      wd = job$wd %||% getwd(),
      env = c("current", job$env %||% character()),
      stdout = job$log,
      stderr = "2>&1",
      cleanup_tree = TRUE
    )
    job$started <- Sys.time()
    job
  }

  repeat {
    while (length(queue) && length(running) < workers) {
      job <- start(queue[[1]])
      queue <- queue[-1]
      running[[job$id]] <- job
    }
    if (!length(running)) {
      break
    }

    conns <- lapply(running, function(j) j$proc$get_poll_connection())
    processx::poll(conns, 200)

    for (id in names(running)) {
      job <- running[[id]]
      elapsed <- as.numeric(difftime(Sys.time(), job$started, units = "secs"))
      timed_out <- elapsed > timeout && job$proc$is_alive()
      if (timed_out) {
        job$proc$kill_tree()
      }
      if (!job$proc$is_alive()) {
        job$proc$wait()
        status <- if (timed_out) NA_integer_ else job$proc$get_exit_status()
        results[[id]] <- list(
          id = id,
          kind = job$kind,
          status = status,
          timed_out = timed_out,
          elapsed = elapsed,
          log = job$log,
          meta = job$meta
        )
        running[[id]] <- NULL
        if (progress) {
          mark <- if (identical(status, 0L)) "\u2714" else "\u2716"
          message(sprintf("  %s %-40s %6.1fs", mark, id, elapsed))
        }
      }
    }
  }
  results
}

`%||%` <- function(a, b) if (is.null(a)) b else a

rscript <- function() file.path(R.home("bin"), "Rscript")
rcmd <- function() file.path(R.home("bin"), "R")
