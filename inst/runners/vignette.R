# Re-build one vignette (this runs all of its code) against the installed
# package. Usage: Rscript vignette.R <vignette file> <builder pkgs, comma sep>
args <- commandArgs(TRUE)
file <- args[[1]]
builders <- if (length(args) > 1 && nzchar(args[[2]])) {
  strsplit(args[[2]], ",")[[1]]
} else {
  character()
}
for (b in builders) {
  loadNamespace(b)
}

setwd(dirname(file))
res <- tools::buildVignette(
  file,
  dir = dirname(file),
  tangle = FALSE,
  quiet = FALSE,
  clean = TRUE
)
cat("\nBuilt:", res, "\n")
