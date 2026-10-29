#!/usr/bin/env bash
# Benchmark rcmdcheck::rcmdcheck() against fastrcmdcheck::fastcheck().
# Usage: bench/bench.sh <fixtures dir> <results dir> [cores] [first cpu]
# All runs are pinned to the same <cores> CPUs (default 4, a GitHub runner),
# starting at <first cpu> (default 0) so several benchmarks can run side by side.
set -euo pipefail
FIX=${1:?fixtures dir}
OUT=${2:?results dir}
CORES=${3:-4}
FIRST=${4:-0}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PIN="taskset -c $FIRST-$((FIRST + CORES - 1))"
# no network variance (remote CRAN, URL and time-server lookups)
export _R_CHECK_CRAN_INCOMING_REMOTE_=false _R_CHECK_FUTURE_FILE_TIMESTAMPS_=false _R_CHECK_SYSTEM_CLOCK_=false
ARGS='c("--no-manual", "--as-cran")'
CSV="$OUT/results.csv"
echo "package,scenario,seconds,errors,warnings,notes" > "$CSV"

run() { # name scenario cmd...
  local pkg=$1 scen=$2; shift 2
  local t0=$(date +%s.%N)
  "$@" > "$OUT/$pkg-$scen.log" 2>&1 || true
  local t1=$(date +%s.%N)
  local s=$(awk "BEGIN{print $t1 - $t0}")
  local counts
  counts=$(Rscript -e "x <- readRDS('$OUT/$pkg-$scen.rds'); cat(length(x\$errors), length(x\$warnings), length(x\$notes), sep=',')" 2>/dev/null || echo "NA,NA,NA")
  printf "%-10s %-16s %7.1fs  E/W/N=%s\n" "$pkg" "$scen" "$s" "$counts"
  echo "$pkg,$scen,$s,$counts" >> "$CSV"
}

for dir in "$FIX"/*/; do
  pkg=$(basename "$dir")
  dir=$(cd "$dir" && pwd)
  # Warm the cargo registry so downloads don't count against anyone.
  if [ -f "$dir/src/rust/Cargo.toml" ]; then cargo fetch --manifest-path "$dir/src/rust/Cargo.toml" -q; fi
  cache="$OUT/cache-$pkg"
  rm -rf "$cache" "$OUT/$pkg-"*

  run "$pkg" rcmdcheck $PIN Rscript -e "x <- rcmdcheck::rcmdcheck('$dir', args = $ARGS, build_args = '--no-manual', error_on = 'never', check_dir = '$OUT/$pkg-rcmdcheck'); saveRDS(x, '$OUT/$pkg-rcmdcheck.rds')"

  # Same, but with parallel make: isolates what plain -j buys.
  run "$pkg" rcmdcheck-j $PIN env MAKEFLAGS=-j$CORES Rscript -e "x <- rcmdcheck::rcmdcheck('$dir', args = $ARGS, build_args = '--no-manual', error_on = 'never', check_dir = '$OUT/$pkg-rcmdcheck-j'); saveRDS(x, '$OUT/$pkg-rcmdcheck-j.rds')"

  fc() { # scenario profile
    run "$pkg" "$1" $PIN Rscript -e "x <- fastrcmdcheck::fastcheck('$dir', args = $ARGS, jobs = $CORES, profile = '$2', cache_dir = '$cache-$2', check_dir = '$OUT/$pkg-$1'); saveRDS(x, '$OUT/$pkg-$1.rds')"
  }
  fc fast-cold faithful
  fc fast-warm faithful
  fc fastprof-cold fast
  fc fastprof-warm fast
done
echo "results: $CSV"
