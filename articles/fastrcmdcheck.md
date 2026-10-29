# Fast, Parallel, Cache-Aware R CMD Check for CI

``` r

library(fastrcmdcheck)
```

## fastrcmdcheck

A drop-in, substantially faster alternative to rcmdcheck for continuous
integration.

## Installation

Install with

``` r

remotes::install_github(
    repo = "grantn5/fastrcmdcheck"
  )
```

## Required knowledge

> 📌: Specify the required background knowledge that is needed to
> understand and apply this package e.g. Perturb-seq if this is a
> package aimed at automating guide assignment.

## Input data

> 📌: Often, bioinformatic input data is varied and complex with several
> different (pre)processing steps. The aim of this section is to
> describe the required input for your package along with any specific
> preprocessing steps that are required.

## Usage

> 📌: Include examples of the functionality of `fastrcmdcheck`. For
> instance, if your package is designed to automate a specific workflow,
> then detail all the steps required with a small, example dataset; try
> to explain the rationale behind each step. Make sure you also cover
> any edge cases and potential caveats that may not be obvious to a user
> without deep-diving into the code itself.

## Session info

Show/hide

    #> ─ Session info ───────────────────────────────────────────────────────────────────────────────────────────────────────
    #>  setting  value
    #>  version  R version 4.6.1 (2026-06-24)
    #>  os       Ubuntu 24.04.5 LTS
    #>  system   x86_64, linux-gnu
    #>  ui       X11
    #>  language en
    #>  collate  C.UTF-8
    #>  ctype    C.UTF-8
    #>  tz       UTC
    #>  date     2026-10-29
    #>  pandoc   3.8.3 @ /opt/hostedtoolcache/pandoc/3.8.3/x64/ (via rmarkdown)
    #>  quarto   1.10.19 @ /usr/local/bin/quarto
    #>
    #> ─ Packages ───────────────────────────────────────────────────────────────────────────────────────────────────────────
    #>  package       * version date (UTC) lib source
    #>  cli             3.6.6   2026-04-09 [1] RSPM
    #>  digest          0.6.39  2025-11-19 [1] RSPM
    #>  evaluate        1.0.5   2025-08-27 [1] RSPM
    #>  fastmap         1.2.0   2024-05-15 [1] RSPM
    #>  fastrcmdcheck * 0.1.0   2026-10-29 [1] local
    #>  htmltools       0.5.9   2025-12-04 [1] RSPM
    #>  jsonlite        2.0.0   2025-03-27 [1] RSPM
    #>  knitr           1.52    2026-09-06 [1] RSPM
    #>  otel            0.2.0   2025-08-29 [1] RSPM
    #>  rlang           1.3.0   2026-07-05 [1] RSPM
    #>  rmarkdown       2.32    2026-09-01 [1] RSPM
    #>  sessioninfo   * 1.2.4   2026-06-04 [1] RSPM
    #>  xfun            0.62    2026-10-16 [1] RSPM
    #>  yaml            2.3.12  2025-12-10 [1] RSPM
    #>
    #>  [1] /home/runner/work/_temp/Library
    #>  [2] /opt/R/4.6.1/lib/R/site-library
    #>  [3] /opt/R/4.6.1/lib/R/library
    #>  * ── Packages attached to the search path.
    #>
    #> ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
