# Command line entry point

\`Rscript -e 'fastrcmdcheck::fastcheck_cli()' – \[options\] \[path\]\`,
or the \`fastcheck\` script in \`system.file("bin", package =
"fastrcmdcheck")\`. Exits non-zero when problems at or above
\`–error-on\` are found.

## Usage

``` r
fastcheck_cli(argv = commandArgs(TRUE))
```

## Arguments

- argv:

  Command line arguments.
