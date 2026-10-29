#' Parse an R CMD check log (`00check.log`)
#'
#' @param lines Lines of the log, or a path to it.
#' @return Data frame with columns `check`, `status` and `details`.
#' @export
parse_check_log <- function(lines) {
  if (length(lines) == 1 && file.exists(lines)) {
    lines <- readLines(lines, warn = FALSE, encoding = "UTF-8")
  }
  starts <- which(startsWith(lines, "* "))
  empty <- data.frame(
    check = character(),
    status = character(),
    details = character(),
    stringsAsFactors = FALSE
  )
  if (!length(starts)) {
    return(empty)
  }
  ends <- c(starts[-1] - 1L, length(lines))
  status_re <- "\\s*\\.\\.\\.\\s*(\\[[^]]*\\]\\s*)?(OK|NOTE|WARNING|ERROR|NONE|SKIPPED|INFO)\\s*$"

  rows <- lapply(seq_along(starts), function(i) {
    head <- sub("^\\* ", "", lines[starts[i]])
    body <- if (ends[i] > starts[i]) {
      lines[(starts[i] + 1L):ends[i]]
    } else {
      character()
    }
    status <- NA_character_
    m <- regmatches(head, regexec(status_re, head))[[1]]
    if (length(m)) {
      status <- m[3]
      head <- sub(status_re, "", head)
    } else {
      hit <- grep("^\\s*(OK|NOTE|WARNING|ERROR|SKIPPED|INFO)\\s*$", body)
      if (length(hit)) {
        status <- trimws(body[hit[1]])
        body <- body[-hit[1]]
      }
      head <- sub("\\s*\\.\\.\\.\\s*$", "", head)
    }
    body <- body[!grepl("^Status:", body)]
    data.frame(
      check = head,
      status = status,
      details = paste(trimws(body, "right"), collapse = "\n"),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out <- out[!is.na(out$status), , drop = FALSE]
  rownames(out) <- NULL
  out
}
