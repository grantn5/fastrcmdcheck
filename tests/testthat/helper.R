# Temp dirs live under tempdir() and are removed with the R session.
tempdir_new <- function() {
  d <- tempfile("fastrcmdcheck-test-")
  dir.create(d)
  d
}

fixture_pkg <- function(name, files) {
  p <- file.path(tempdir_new(), name)
  for (f in names(files)) {
    dir.create(dirname(file.path(p, f)), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[f]], file.path(p, f))
  }
  p
}
