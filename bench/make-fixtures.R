# Generate synthetic benchmark packages that mimic typical CI workloads:
#   cppheavy - Rcpp package with template-heavy C++, testthat suite, vignette
#   rustpkg  - C + Rust (staticlib with a crates.io dependency), testthat suite
#   rheavy   - pure R, many tests / examples / two vignettes
# Usage: Rscript bench/make-fixtures.R <outdir>
args <- commandArgs(TRUE)
out <- if (length(args)) args[[1]] else "bench/fixtures"
dir.create(out, recursive = TRUE, showWarnings = FALSE)

w <- function(path, ...) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(...), path)
}

desc <- function(pkg, extra = character()) {
  c(
    paste("Package:", pkg),
    "Title: Benchmark Fixture",
    "Version: 0.1.0",
    "Authors@R: person(\"Bench\", \"Mark\", email = \"bench@example.com\", role = c(\"aut\", \"cre\"))",
    "Description: Synthetic package used to benchmark R CMD check runtimes.",
    "License: MIT + file LICENSE",
    "Encoding: UTF-8",
    extra
  )
}

test_file <- function(pkg, i, call) {
  c(
    sprintf("test_that(\"workload %d is stable\", {", i),
    "  set.seed(1)",
    "  acc <- 0",
    "  for (k in 1:60) acc <- acc + sum(sort(stats::runif(2e5)))",
    "  expect_true(acc > 0)",
    sprintf("  expect_equal(%s, %s)", call, call),
    "})"
  )
}

vignette <- function(pkg, title) {
  c(
    "---",
    sprintf("title: \"%s\"", title),
    "output: rmarkdown::html_vignette",
    "vignette: >",
    sprintf("  %%\\VignetteIndexEntry{%s}", title),
    "  %\\VignetteEngine{knitr::rmarkdown}",
    "  %\\VignetteEncoding{UTF-8}",
    "---",
    "",
    "```{r}",
    sprintf("library(%s)", pkg),
    "x <- vapply(1:40, function(i) sum(sort(runif(2e5))), 0)",
    "summary(x)",
    "plot(x)",
    "```"
  )
}

# ---- cppheavy ----------------------------------------------------------------
p <- file.path(out, "cppheavy")
unlink(p, recursive = TRUE)
w(
  file.path(p, "DESCRIPTION"),
  desc(
    "cppheavy",
    c(
      "Imports: Rcpp",
      "LinkingTo: Rcpp",
      "Suggests: testthat (>= 3.0.0), knitr, rmarkdown",
      "VignetteBuilder: knitr",
      "Config/testthat/edition: 3"
    )
  )
)
w(file.path(p, "LICENSE"), "YEAR: 2026", "COPYRIGHT HOLDER: Bench")
w(
  file.path(p, "NAMESPACE"),
  "useDynLib(cppheavy, .registration = TRUE)",
  "importFrom(Rcpp, sourceCpp)",
  "exportPattern(\"^work_\")"
)
n_cpp <- 10
for (i in seq_len(n_cpp)) {
  w(
    file.path(p, "src", sprintf("work%02d.cpp", i)),
    "#include <Rcpp.h>",
    "#include <regex>",
    "#include <random>",
    "#include <map>",
    "#include <unordered_map>",
    "#include <sstream>",
    "#include <algorithm>",
    "#include <functional>",
    "#include <tuple>",
    "#include <variant>",
    "template <typename T, int D> struct Deep {",
    "  static T run(T x) { return Deep<T, D - 1>::run(x) * T(1.0001) + T(D % 3); }",
    "};",
    "template <typename T> struct Deep<T, 0> { static T run(T x) { return x; } };",
    "template <typename K, typename V> std::map<K, V> tally(const std::vector<K>& xs) {",
    "  std::map<K, V> m; for (auto& x : xs) m[x] += V(1); return m; }",
    "// [[Rcpp::export]]",
    sprintf("double work_%02d(int n) {", i),
    "  std::mt19937 gen(42); std::normal_distribution<double> d(0, 1);",
    "  std::vector<int> xs; std::ostringstream os;",
    "  for (int k = 0; k < n; ++k) { xs.push_back(int(d(gen) * 10)); os << xs.back() << ' '; }",
    "  std::regex re(\"-?[0-9]+\"); std::string s = os.str();",
    "  auto it = std::sregex_iterator(s.begin(), s.end(), re);",
    "  double hits = std::distance(it, std::sregex_iterator());",
    "  auto m = tally<int, double>(xs); std::unordered_map<std::string, std::variant<int, double>> u;",
    "  for (auto& kv : m) u[std::to_string(kv.first)] = kv.second;",
    sprintf(
      "  return Deep<double, 120>::run(hits) + Deep<float, 90>::run(m.size()) + Deep<long double, 60>::run(u.size()) + %d;",
      i
    ),
    "}"
  )
}
Rcpp::compileAttributes(p)
w(
  file.path(p, "man", "work.Rd"),
  "\\name{work}",
  sprintf("\\alias{work_%02d}", seq_len(n_cpp)),
  "\\title{Workloads}",
  "\\usage{",
  sprintf("work_%02d(n)", seq_len(n_cpp)),
  "}",
  "\\arguments{\\item{n}{Size.}}",
  "\\value{A number.}",
  "\\description{Do work.}",
  "\\examples{",
  sprintf("work_%02d(100)", seq_len(n_cpp)),
  "}"
)
w(
  file.path(p, "tests", "testthat.R"),
  "library(testthat)",
  "library(cppheavy)",
  "test_check(\"cppheavy\")"
)
for (i in 1:12) {
  w(
    file.path(p, "tests", "testthat", sprintf("test-work%02d.R", i)),
    test_file("cppheavy", i, sprintf("work_%02d(500)", (i - 1) %% n_cpp + 1))
  )
}
w(file.path(p, "vignettes", "intro.Rmd"), vignette("cppheavy", "Intro"))

# ---- rustpkg -------------------------------------------------------------------
p <- file.path(out, "rustpkg")
unlink(p, recursive = TRUE)
w(
  file.path(p, "DESCRIPTION"),
  desc(
    "rustpkg",
    c(
      "Suggests: testthat (>= 3.0.0)",
      "SystemRequirements: Cargo (Rust's package manager), rustc",
      "Config/testthat/edition: 3"
    )
  )
)
w(file.path(p, "LICENSE"), "YEAR: 2026", "COPYRIGHT HOLDER: Bench")
w(
  file.path(p, "NAMESPACE"),
  "useDynLib(rustpkg, .registration = TRUE)",
  "export(count_matches)"
)
w(file.path(p, ".Rbuildignore"), "^src/rust/target$")
w(
  file.path(p, "R", "count.R"),
  "count_matches <- function(pattern, x) .Call(C_count_matches, pattern, x)"
)
w(
  file.path(p, "src", "init.c"),
  "#include <R.h>",
  "#include <Rinternals.h>",
  "#include <R_ext/Rdynload.h>",
  "int rs_count_matches(const char *pat, const char *txt);",
  "SEXP count_matches(SEXP pat, SEXP x) {",
  "  return Rf_ScalarInteger(rs_count_matches(CHAR(STRING_ELT(pat, 0)), CHAR(STRING_ELT(x, 0))));",
  "}",
  "static const R_CallMethodDef calls[] = {{\"C_count_matches\", (DL_FUNC) &count_matches, 2}, {NULL, NULL, 0}};",
  "void R_init_rustpkg(DllInfo *dll) { R_registerRoutines(dll, NULL, calls, NULL, NULL); R_useDynamicSymbols(dll, FALSE); R_forceSymbols(dll, TRUE); }"
)
w(
  file.path(p, "src", "Makevars"),
  "TARGET_DIR = ./rust/target",
  "LIBDIR = $(TARGET_DIR)/release",
  "STATLIB = $(LIBDIR)/librustpkg.a",
  "PKG_LIBS = -L$(LIBDIR) -lrustpkg -lpthread -ldl -lm",
  "",
  "all: $(SHLIB)",
  "",
  "$(SHLIB): $(STATLIB)",
  "",
  "$(STATLIB):",
  "\tcargo build --lib --release --manifest-path=./rust/Cargo.toml --target-dir $(TARGET_DIR)",
  "",
  "clean:",
  "\trm -Rf $(SHLIB) $(STATLIB) $(OBJECTS) rust/target"
)
w(
  file.path(p, "src", "rust", "Cargo.toml"),
  "[package]",
  "name = \"rustpkg\"",
  "version = \"0.1.0\"",
  "edition = \"2021\"",
  "",
  "[lib]",
  "crate-type = [\"staticlib\"]",
  "",
  "[dependencies]",
  "regex = \"1\"",
  "serde = { version = \"1\", features = [\"derive\"] }",
  "serde_json = \"1\"",
  "",
  "[profile.release]",
  "lto = true",
  "codegen-units = 1"
)
w(
  file.path(p, "src", "rust", "src", "lib.rs"),
  "use std::ffi::CStr;",
  "use std::os::raw::c_char;",
  "#[derive(serde::Serialize, serde::Deserialize)] struct Hit { n: i32 }",
  "#[no_mangle]",
  "pub extern \"C\" fn rs_count_matches(pat: *const c_char, txt: *const c_char) -> i32 {",
  "    let pat = unsafe { CStr::from_ptr(pat) }.to_string_lossy();",
  "    let txt = unsafe { CStr::from_ptr(txt) }.to_string_lossy();",
  "    let n = match regex::Regex::new(&pat) { Ok(re) => re.find_iter(&txt).count() as i32, Err(_) => -1 };",
  "    let h: Hit = serde_json::from_str(&serde_json::to_string(&Hit { n }).unwrap()).unwrap();",
  "    h.n",
  "}"
)
w(
  file.path(p, "man", "count_matches.Rd"),
  "\\name{count_matches}",
  "\\alias{count_matches}",
  "\\title{Count regex matches}",
  "\\usage{count_matches(pattern, x)}",
  "\\arguments{\\item{pattern}{Regex.}\\item{x}{String.}}",
  "\\value{Integer.}",
  "\\description{Count matches using Rust's regex crate.}",
  "\\examples{count_matches(\"a+\", \"caaandaab\")}"
)
w(
  file.path(p, "tests", "testthat.R"),
  "library(testthat)",
  "library(rustpkg)",
  "test_check(\"rustpkg\")"
)
for (i in 1:8) {
  w(
    file.path(p, "tests", "testthat", sprintf("test-count%02d.R", i)),
    test_file("rustpkg", i, "count_matches(\"a+\", \"caaandaab\")")
  )
}

# ---- rheavy -----------------------------------------------------------------------
p <- file.path(out, "rheavy")
unlink(p, recursive = TRUE)
w(
  file.path(p, "DESCRIPTION"),
  desc(
    "rheavy",
    c(
      "Suggests: testthat (>= 3.0.0), knitr, rmarkdown",
      "VignetteBuilder: knitr",
      "Config/testthat/edition: 3"
    )
  )
)
w(file.path(p, "LICENSE"), "YEAR: 2026", "COPYRIGHT HOLDER: Bench")
w(file.path(p, "NAMESPACE"), "exportPattern(\"^f_\")")
n_fun <- 40
w(
  file.path(p, "R", "funs.R"),
  unlist(lapply(seq_len(n_fun), function(i) {
    c(
      sprintf("f_%02d <- function(n) {", i),
      "  x <- 0",
      "  for (k in seq_len(n)) x <- x + sqrt(k)",
      sprintf("  x + %d", i),
      "}",
      ""
    )
  }))
)
for (i in seq_len(n_fun)) {
  w(
    file.path(p, "man", sprintf("f_%02d.Rd", i)),
    sprintf("\\name{f_%02d}", i),
    sprintf("\\alias{f_%02d}", i),
    sprintf("\\title{Function %d}", i),
    sprintf("\\usage{f_%02d(n)}", i),
    "\\arguments{\\item{n}{Size.}}",
    "\\value{A number.}",
    "\\description{Compute something.}",
    "\\examples{",
    sprintf("f_%02d(1e5)", i),
    "x <- vapply(1:15, function(i) sum(sort(runif(1e5))), 0)",
    "plot(x)",
    "}"
  )
}
w(
  file.path(p, "tests", "testthat.R"),
  "library(testthat)",
  "library(rheavy)",
  "test_check(\"rheavy\")"
)
for (i in 1:24) {
  w(
    file.path(p, "tests", "testthat", sprintf("test-f%02d.R", i)),
    test_file("rheavy", i, sprintf("f_%02d(1e4)", i))
  )
}
w(file.path(p, "vignettes", "one.Rmd"), vignette("rheavy", "One"))
w(file.path(p, "vignettes", "two.Rmd"), vignette("rheavy", "Two"))

message("fixtures written to ", normalizePath(out))
