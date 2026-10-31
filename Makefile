# hildi — developer Makefile
#
#   make            build the example (debug)
#   make test       build & run the fpcunit suite
#   make release    build an optimized example
#   make clean      remove build artifacts
#   make help       show this message

FPC      ?= fpc

# Optional project-local compiler config.
#
# FPC reads ~/.fpc.cfg (and /etc/fpc.cfg) before anything else, so a user-level
# config naming one unit tree shadows a DIFFERENT FPC installation. That is the
# "Can't find unit system" failure: fpcenv's compiler starts, then is pointed at
# the old tree's units.
#
# Every FPC install that ships its own config keeps it at
#   <root>/lib/fpc/etc/fpc.cfg
# so it is derived from the compiler actually in use. When one exists, -n
# ignores the default configs and @<file> loads the matching one. When it does
# not (the classic ~/Library/fpc layout), FPCARGS stays empty and the previous
# behaviour -- including a hand-written ~/.fpc.cfg -- is untouched.
#
# Nothing global is modified, and no project is affected but this one.
#
# Override explicitly if the layout is unusual:
#   make check FPC=/path/to/fpc FPC_CFG=/path/to/fpc.cfg
#
FPC_CFG     ?=
# FPC may be given as a bare name ("fpc") or a path. `$(dir fpc)` is "./", so a
# bare name has to be resolved through PATH first -- otherwise the derivation
# silently finds nothing and the ~/.fpc.cfg shadow comes back on any machine
# whose fpc is a version-managed one.
FPC_BIN     := $(shell command -v $(firstword $(FPC)) 2>/dev/null)
FPC_ROOT_CFG := $(wildcard $(dir $(FPC_BIN))../lib/fpc/etc/fpc.cfg)
ifneq ($(strip $(FPC_CFG)),)
FPCARGS  := -n @$(FPC_CFG)
else ifneq ($(strip $(FPC_ROOT_CFG)),)
FPCARGS  := -n @$(FPC_ROOT_CFG)
else
FPCARGS  :=
endif

SRC      := src
TESTS    := tests
EXAMPLES := examples
BUILD    := build
BIN      := $(BUILD)/bin
DBGUNITS := $(BUILD)/units/debug
RELUNITS := $(BUILD)/units/release
LEAKUNITS:= $(BUILD)/units/leak

# Vendored SQLite: the amalgamation is compiled into a STATIC archive and linked
# into the binaries (no runtime .dylib/.so, no SQLDB). See scripts/fetch-sqlite.sh.
SQLITE_DIR      := deps/sqlite3
LIBSTATIC       := $(BUILD)/libstatic
SQLITE_LIBDIR   := $(LIBSTATIC)
SQLITE_AR       := $(SQLITE_LIBDIR)/libsqlite3.a
UNAME_S         := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SQLITE_CCFLAGS  := -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -mmacosx-version-min=11.0
MBEDTLS_CCFLAGS  := -O2 -mmacosx-version-min=11.0
# macOS links libSystem unconditionally, which already provides the math and
# compiler-runtime symbols. Nothing extra is needed.
SYS_LDFLAGS     :=
else
SQLITE_CCFLAGS  := -O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5
MBEDTLS_CCFLAGS  := -O2 -fPIC
# Linux does not: the vendored archives need symbols from two separate system
# libraries that FPC does not add for us.
#   -lgcc  -> __udivti3, the 64-bit division helper mbedTLS's bignum uses
#   -lm    -> log, used by SQLite's FTS5 bm25 ranking
# Both are present on macOS only because libSystem re-exports them, which is why
# the missing flags went unnoticed until a Linux link.
SYS_LDFLAGS     := -k-lm -k-lgcc
endif
# Link the static archive explicitly (-k), so a system libsqlite3 is never used.
# -Fl is also required: HildiSQLITE declares `external 'sqlite3'`, which makes the
# linker emit -lsqlite3, and without a library path that resolves against the
# SYSTEM sqlite (a dylib on macOS, absent entirely on a bare Fedora). The static
# archive was being passed by -k but the -lsqlite3 it exists to satisfy had
# nowhere to look, so the build failed on Linux with "cannot find -lsqlite3".
SQLITE_LDFLAGS  := -Fl$(abspath $(SQLITE_LIBDIR)) -k$(abspath $(SQLITE_AR))
CC ?= cc
AR ?= ar

# Vendored mbedTLS: compiled into STATIC archives and linked into the binaries
# that speak TLS, so no host OpenSSL is needed. See scripts/fetch-mbedtls.sh.
MBEDTLS_DIR       := deps/mbedtls
MBEDTLS_STAMP     := $(LIBSTATIC)/.mbedtls-built
MBEDTLS_AR        := $(LIBSTATIC)/libmbedtls.a
MBEDTLS_X509_AR   := $(LIBSTATIC)/libmbedx509.a
MBEDTLS_CRYPTO_AR := $(LIBSTATIC)/libmbedcrypto.a
TLS_SHIM_OBJ      := $(LIBSTATIC)/hildi_tls_shim.o
CACERT_PEM        := deps/cacert/cacert.pem
CACERT_GEN_C      := $(BUILD)/gen/cacert_embedded.c
CACERT_OBJ        := $(LIBSTATIC)/cacert_embedded.o
TLS_TEST_SERVER_OBJ := $(LIBSTATIC)/tls_test_server.o
# Link order matters for static archives: shim + CA, then TLS, X.509, crypto.
TLS_LDFLAGS       := -k$(abspath $(TLS_SHIM_OBJ)) -k$(abspath $(CACERT_OBJ)) \
                     -k$(abspath $(MBEDTLS_AR)) -k$(abspath $(MBEDTLS_X509_AR)) \
                     -k$(abspath $(MBEDTLS_CRYPTO_AR))
TLS_CCFLAGS       := -O2 -fPIC -I$(MBEDTLS_DIR)/include -I$(SRC)
ifeq ($(UNAME_S),Darwin)
TLS_CCFLAGS       += -mmacosx-version-min=11.0
endif

# Language and strictness. Every unit self-declares {$mode delphi}, so the
# command line does NOT force -Mdelphi: -Sh keeps ansistrings, -Sew turns
# warnings into errors.
MODE      := -Sh
STRICT    := -vw -Sew
DEBUG     := $(MODE) $(STRICT) -O- -Crtio -Sa -gl
RELEASE   := $(MODE) $(STRICT) -O2 -CX -XX -Xs
# -gh links heaptrc into the test binary for leak checking.
LEAKFLAGS := $(MODE) $(STRICT) -O- -Crtio -Sa -gh -gl
# heaptrc: exit 203 if anything is still allocated; stay quiet when clean.
HEAPTRC   := haltonnotreleased:skipifnoleaks

# TDD knobs:
#   make shell-ast [SCRIPT='echo hi']       -> dump a parsed shell AST
#   make test SUITE=TAgentPoolTest          -> one suite
#   make test SUITE=TestReportsExitCode     -> one test method
#   make test SUITE=A,B                     -> a list
#   make watch [TARGET=test-leak]           -> auto-rerun on source changes
SUITE  ?=
TARGET ?= test
ARGS   ?=

TESTARGS := --format=plain
ifneq ($(SUITE),)
TESTARGS += --suite=$(SUITE)
else
TESTARGS += --all
endif

LIB_SRCS  := $(wildcard $(SRC)/*.pas)
ASYNC_SRCS := $(wildcard $(SRC)/async/*.pas)
SHELL_SRCS := $(wildcard $(SRC)/shell/*.pas)
TUILIB_SRCS := $(wildcard $(SRC)/tui/core/*.pas) $(wildcard $(SRC)/tui/widgets/*.pas)
CHANGES_SRCS := $(wildcard $(SRC)/changes/*.pas)
MARKDOWN_SRCS := $(wildcard $(SRC)/markdown/*.pas)
FILEIGNORE_SRCS := $(wildcard $(SRC)/fileignore/*.pas)
TEST_SRCS := $(wildcard $(TESTS)/*.pas)

.PHONY: all test test-leak watch check release clean help libsqlite libmbedtls deps \
        store-demo agent-cli release-agent-cli tui-demo widgets-demo layout-demo \
        headless-agent tui-agent bench perf agents agent-% mcp-smoke smoke smoke-list async-standalone async-bench async-freeze async-examples

# Fetch and verify every vendored dependency. The README tells a new contributor
# to run this first, and it used to be a silent no-op: there was no `deps` rule,
# so make matched the `deps/` DIRECTORY and reported "Nothing to be done" while
# fetching nothing. A missing rule that looks like success is worse than an error.
deps: libsqlite libmbedtls
	@scripts/fetch-cacert.sh
	@echo "deps: okay"

all: $(BIN)/hildi-demo

# Build the vendored SQLite static archive; fetches the amalgamation if missing.
libsqlite: $(SQLITE_AR)

$(SQLITE_AR): $(SQLITE_DIR)/sqlite3.c
	@mkdir -p $(SQLITE_LIBDIR)
	$(CC) $(SQLITE_CCFLAGS) -c -o $(SQLITE_LIBDIR)/sqlite3.o $<
	$(AR) rcs $@ $(SQLITE_LIBDIR)/sqlite3.o

$(SQLITE_DIR)/sqlite3.c:
	@scripts/fetch-sqlite.sh

# Build the vendored mbedTLS archives, the CA embed, and the Pascal TLS shim.
libmbedtls: $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ)

$(MBEDTLS_STAMP):
	@scripts/fetch-mbedtls.sh
	$(MAKE) -C $(MBEDTLS_DIR) -j4 lib CFLAGS='$(MBEDTLS_CCFLAGS)'
	@mkdir -p $(LIBSTATIC)
	cp $(MBEDTLS_DIR)/library/libmbedtls.a $(MBEDTLS_DIR)/library/libmbedx509.a $(MBEDTLS_DIR)/library/libmbedcrypto.a $(LIBSTATIC)/
	@touch $@

$(TLS_SHIM_OBJ): $(SRC)/hildi_tls_shim.c $(SRC)/hildi_tls_shim.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -c -o $@ $(SRC)/hildi_tls_shim.c

$(CACERT_PEM):
	@scripts/fetch-cacert.sh

$(CACERT_GEN_C): $(CACERT_PEM) scripts/gen-cacert-embed.sh
	@scripts/gen-cacert-embed.sh

$(CACERT_OBJ): $(CACERT_GEN_C) $(SRC)/hildi_tls_shim.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -c -o $@ $(CACERT_GEN_C)

# Test-only mbedTLS echo server; compiled into the test binaries only.
$(TLS_TEST_SERVER_OBJ): $(TESTS)/tls_test_server.c $(TESTS)/tls_test_server.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -I$(TESTS) -c -o $@ $(TESTS)/tls_test_server.c

store-demo: libsqlite $(BIN)/hildi-store-demo

$(BIN)/hildi-store-demo: $(EXAMPLES)/store_demo.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

agent-cli: libsqlite libmbedtls $(BIN)/hildi-agent-cli

$(BIN)/hildi-agent-cli: $(EXAMPLES)/agent_cli.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Live MCP calibration smoke: drives the MCP client against a real MCP server
# (the Playwright container over docker stdio). Needs Docker; not part of
# `make check` (the suite is hermetic). See examples/mcp_smoke.pas.
mcp-smoke: libsqlite libmbedtls $(BIN)/mcp-smoke
	$(BIN)/mcp-smoke

$(BIN)/mcp-smoke: $(EXAMPLES)/mcp_smoke.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Optimized, self-contained production binary (static SQLite, no runtime libs).
release-agent-cli: libsqlite libmbedtls $(BIN)/hildi-agent-cli-release

$(BIN)/hildi-agent-cli-release: $(EXAMPLES)/agent_cli.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(FPCARGS) $(RELEASE) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(RELUNITS) -FE$(BIN) -o$@ $<

$(BIN)/hildi-demo: $(EXAMPLES)/demo_harness.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Interactive TUI demonstration: build, then run it in the terminal.
tui-demo: $(BIN)/hildi-demo
	$(BIN)/hildi-demo

$(BIN)/hildi-demo: $(EXAMPLES)/tui_demo.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Widget-kit demo: a list, a preview panel, and focusable buttons. Builds and
# runs; Tab/Shift-Tab or click to focus, Enter/Space to activate, q to quit.
widgets-demo: $(BIN)/hildi-widgets-demo
	$(BIN)/hildi-widgets-demo

$(BIN)/hildi-widgets-demo: $(EXAMPLES)/tui_widgets_demo.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Mock of the Board Dashboard: three zones over static data, so the operator can
# judge the layout before the feature is specified. Reads no store, writes none.
# See docs/features/Board_Dashboard/FEATURE.md.
dashboard-mock: $(BIN)/hildi-dash-mock
	$(BIN)/hildi-dash-mock

$(BIN)/hildi-dash-mock: $(EXAMPLES)/dashboard_mock.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# The real dashboard: opens this workspace's store and draws it. A viewer with
# one write deferred; it links no agent-loop unit, the same closure discipline
# the TUI client is held to. See docs/features/Board_Dashboard/FEATURE.md.
dashboard: libsqlite libmbedtls $(BIN)/hildi-dash
	$(BIN)/hildi-dash

$(BIN)/hildi-dash: $(EXAMPLES)/dashboard.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Layout exploration: a responsive two-column harness layout (files + editor |
# chat column). The chat column has an optional side panel and a persistent
# bottom input panel. The split appears only when the terminal is wider than 180
# columns; Ctrl-B toggles the side panel, Ctrl-C quits.
layout-demo: $(BIN)/hildi-layout-demo
	$(BIN)/hildi-layout-demo

$(BIN)/hildi-layout-demo: $(EXAMPLES)/tui_layout_demo.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Headless agent: hosts a session's runtime; spawned detached by the TUI or the
# CLI. No terminal. A client finds it as a sibling (or via HILDI_RUNTIME_BIN).
headless-agent: libsqlite libmbedtls $(BIN)/hildi-agent

$(BIN)/hildi-agent: $(EXAMPLES)/headless_agent.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(ASYNC_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -Fu$(SRC)/async -Fu$(SRC)/shell -Fu$(SRC)/changes -Fu$(SRC)/markdown -Fu$(SRC)/fileignore -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Full-screen agent harness (conversation + approvals + sessions). Builds and
# runs; Ctrl-C quits. Drives the headless agent. A pure client: no engine.
tui-agent: headless-agent $(BIN)/hildi
	$(BIN)/hildi $(ARGS)

$(BIN)/hildi: $(EXAMPLES)/tui_agent.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(ASYNC_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	@# The TUI is a pure client: no agent, loop, tool or runtime unit links here.
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -Fu$(SRC)/async -Fu$(SRC)/shell -Fu$(SRC)/changes -Fu$(SRC)/markdown -Fu$(SRC)/fileignore -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Printable wall-clock benchmark. `make bench ARGS=--real` measures the real
# terminal; `make perf` asserts the budgets and is not part of `make check`.
bench: $(BIN)/hildi-bench
	$(BIN)/hildi-bench $(ARGS)

perf: $(BIN)/hildi-bench
	$(BIN)/hildi-bench --assert

$(BIN)/hildi-bench: $(EXAMPLES)/tui_bench.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test: libsqlite libmbedtls $(BIN)/hildi-tests
	$(BIN)/hildi-tests $(TESTARGS)

# The isolation gate: build a program that uses ONLY the async library, with no
# harness unit on the path. If the library ever depends on the harness, this
# fails to compile - which is what keeps it extractable.
async-standalone: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/async -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/async-standalone $(EXAMPLES)/async_standalone.pas

# The same gate for the shell library: compile and run a program that uses ONLY
# src/shell, with no harness unit on the path.
shell-standalone: $(SHELL_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/shell -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/shell-standalone $(EXAMPLES)/shell_standalone.pas
	$(BIN)/shell-standalone

# The same gate for TUI CORE: compile and run a program that uses ONLY
# src/tui/core, with no widget, harness or agent unit on the search path. Core
# is meant to be pure substrate (geometry, surfaces, input decoding, grapheme
# width, theming); the composite widgets in src/tui/widgets are allowed to be
# complex and are deliberately NOT on this path.
#
# If this target fails, the split is wrong - a core unit reached into the
# widget kit or into the harness, and the purity claim in TUI_Core's spec is
# false. That is exactly the failure this exists to catch.
tui-standalone: $(wildcard $(SRC)/tui/core/*.pas)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/tui/core -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/tui-standalone $(EXAMPLES)/tui_standalone.pas
	$(BIN)/tui-standalone

# The same gate for the Changes library: compile and run a program that uses ONLY
# src/changes, with no harness unit on the search path.
changes-standalone: $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/changes -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/changes-standalone $(EXAMPLES)/changes_standalone.pas
	$(BIN)/changes-standalone

# The same gate for the Markdown library: compile and run a program that uses
# ONLY src/markdown, with neither a harness unit nor `tui.*` on the search path.
# A dependency on either fails the build here - this is the feature's central
# claim (docs/features/Markdown_Viewer/Markdown_v1.SPEC.md 4.4).
markdown-standalone: $(MARKDOWN_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/markdown -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/markdown-standalone $(EXAMPLES)/markdown_standalone.pas
	$(BIN)/markdown-standalone

# A visible demo of the STREAMING parser: feed a document a few characters at a
# time and watch finalised blocks accumulate while the open tail stays raw text.
#   make markdown-stream-demo
#   make markdown-stream-demo ARGS='docs/features/FEATURES.md 7'
markdown-stream-demo: $(MARKDOWN_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/markdown -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/markdown-stream-demo $(EXAMPLES)/markdown_stream_demo.pas
	$(BIN)/markdown-stream-demo $(ARGS)

# A developer demo: parse sample scripts and print the AST the library built.
# Pass a script to dump just that one: make shell-ast SCRIPT='echo hi | cat'
shell-ast: $(SHELL_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/shell -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/shell-ast-dump $(EXAMPLES)/shell_ast_dump.pas
	$(BIN)/shell-ast-dump $(SCRIPT)

# Developer report: the commands and literal flags the corpus actually uses,
# parsed with the library. Informs which commands/options the tier should add.
shell-flags: $(SHELL_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/shell -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/shell-flag-report $(EXAMPLES)/shell_flag_report.pas
	$(BIN)/shell-flag-report $(CORPUS) $(TOP)

# A release build of the Async Core throughput benchmark.
async-bench: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(FPCARGS) $(RELEASE) -Fu$(SRC)/async -FU$(RELUNITS) -FE$(BIN) -o$(BIN)/async-bench $(EXAMPLES)/async_bench.pas
	$(BIN)/async-bench

# The before/after repro for the TUI freeze (the drain shape).
async-freeze: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(FPCARGS) $(RELEASE) -Fu$(SRC)/async -FU$(RELUNITS) -FE$(BIN) -o$(BIN)/async-freeze $(EXAMPLES)/async_freeze_bench.pas
	$(BIN)/async-freeze

# The three worked examples (CLI Await, UI ObserveOn, virtual clock), run so the
# output is visible. Uses only the async library.
async-examples: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) -Fu$(SRC)/async -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/async-examples $(EXAMPLES)/async_examples.pas
	$(BIN)/async-examples

$(BIN)/hildi-tests: $(TESTS)/HildiTests.pas $(TEST_SRCS) $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(ASYNC_SRCS) $(SHELL_SRCS) $(CHANGES_SRCS) $(MARKDOWN_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ) $(TLS_TEST_SERVER_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(SYS_LDFLAGS) -k$(abspath $(TLS_TEST_SERVER_OBJ)) $(TLS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -Fu$(SRC)/async -Fu$(SRC)/shell -Fu$(SRC)/changes -Fu$(SRC)/markdown -Fu$(SRC)/fileignore -Fu$(TESTS) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test-leak: libsqlite libmbedtls $(BIN)/hildi-tests-leak
	HEAPTRC=$(HEAPTRC) $(BIN)/hildi-tests-leak $(TESTARGS)

# The leak gate, one process per suite, in parallel. Same binary and same HEAPTRC
# setting; only the process shape differs. Worth having because the leak run is
# the second-longest part of `make check` (~103 s of a ~275 s gate) and it was
# the last piece still paying the single-process cost.
test-leak-parallel: libsqlite libmbedtls $(BIN)/hildi-tests-leak \
    $(BIN)/hildi-agent
	HILDI_TEST_BIN=$(BIN)/hildi-tests-leak HEAPTRC=$(HEAPTRC) \
	    scripts/test-parallel.sh $(SUITE)

# Auto-rerun TARGET (default: test) whenever sources change.
watch:
	@scripts/watch.sh $(TARGET)

$(BIN)/hildi-tests-leak: $(TESTS)/HildiTests.pas $(TEST_SRCS) $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(ASYNC_SRCS) $(SHELL_SRCS) $(CHANGES_SRCS) $(MARKDOWN_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ) $(TLS_TEST_SERVER_OBJ)
	@mkdir -p $(BIN) $(LEAKUNITS)
	$(FPC) $(FPCARGS) $(LEAKFLAGS) $(SQLITE_LDFLAGS) $(SYS_LDFLAGS) -k$(abspath $(TLS_TEST_SERVER_OBJ)) $(TLS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -Fu$(SRC)/async -Fu$(SRC)/shell -Fu$(SRC)/changes -Fu$(SRC)/markdown -Fu$(SRC)/fileignore -Fu$(TESTS) -FU$(LEAKUNITS) -FE$(BIN) -o$@ $<

# Live smoke: drive the REAL headless runtime through a scripted turn against a
# loopback fake provider. Hermetic (loopback only, ephemeral port, temp store);
# safe in `make check`, but kept separate because it forks a process. Needs the
# runtime binary, so it depends on `headless-agent`. See docs/features/Live_Smoke/.
smoke: libsqlite libmbedtls headless-agent $(BIN)/hildi-smoke
	HILDI_RUNTIME_BIN=$(BIN)/hildi-agent $(BIN)/hildi-smoke $(if $(SCENARIO),--scenario $(SCENARIO),)

smoke-list: libsqlite libmbedtls $(BIN)/hildi-smoke
	$(BIN)/hildi-smoke --list

$(BIN)/hildi-smoke: $(EXAMPLES)/smoke.pas $(TESTS)/smoke_runner.pas $(TESTS)/smoke_provider.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(FPCARGS) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) $(SYS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -Fu$(SRC)/async -Fu$(TESTS) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# All quality gates, for CI: functional tests + leak check + library isolation.
# The two suite runs go one-process-per-suite in parallel (see
# scripts/test-parallel.sh): ~21 s each instead of ~169 s and ~103 s, and the
# isolation also removes the intra-process state pollution that makes a
# single-process run of the whole suite report failures that are not real.
check: test-parallel test-leak-parallel shell-standalone markdown-standalone

# The same functional suite, one process per suite, in parallel. Measured on a
# 10-core machine: ~169 s and 36 spurious failures as one process, ~22 s and 0
# failures this way. The isolation matters more than the speed - those 36 were
# intra-process state pollution, and they pass when a suite gets its own process.
# Not a replacement for `check`: the leak gate needs one process per suite too
# before it can be split. See scripts/test-parallel.sh.
test-parallel: libsqlite libmbedtls $(BIN)/hildi-tests \
    $(BIN)/hildi-agent
	scripts/test-parallel.sh $(SUITE)

release: $(BIN)/hildi-demo-release

$(BIN)/hildi-demo-release: $(EXAMPLES)/demo_harness.pas $(LIB_SRCS) $(TUILIB_SRCS) $(MARKDOWN_SRCS) $(CHANGES_SRCS)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(FPCARGS) $(RELEASE) -Fu$(SRC) -Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets -FU$(RELUNITS) -FE$(BIN) -o$@ $<

clean:
	rm -rf $(BUILD)
	rm -f $(SRC)/*.o $(SRC)/*.ppu
	rm -f $(TESTS)/*.o $(TESTS)/*.ppu
	rm -f $(EXAMPLES)/*.o $(EXAMPLES)/*.ppu

# Parallel agent playgrounds (git worktrees under .worktrees/, see
# docs/guidelines/source-control.md). The ACTIVE file names the playground
# that `make agent-<target>` delegates to; per-call override wins:
#   make agent-tui ACTIVE=mcp
WORKTREES  := .worktrees
ACTIVE     ?= $(shell cat $(WORKTREES)/ACTIVE 2>/dev/null)

# Create a BUILDABLE worktree. Never call `git worktree add` directly for this
# project: a bare checkout has no deps/ and no build/, so it cannot compile, and
# the integration suites then fail ~36 tests for a reason unrelated to the code.
#   make worktree-add NAME=feature WT_ARGS="-b agent/feature"
worktree-add:
	@test -n "$(NAME)" || { echo "usage: make worktree-add NAME=<dir> [WT_ARGS='-b <branch>']"; exit 2; }
	@scripts/worktree-add.sh $(WORKTREES)/$(NAME) $(WT_ARGS)

agents:
	@echo "playgrounds (.worktrees/):"
	@for d in $(WORKTREES)/*/; do \
		[ -d "$$d" ] || continue; \
		name=$$(basename $$d); \
		if [ -f "$$d/.git" ] || [ -d "$$d/.git" ]; then \
			ahead=$$(git -C "$$d" rev-list --count main..HEAD 2>/dev/null || echo '?'); \
			behind=$$(git -C "$$d" rev-list --count HEAD..main 2>/dev/null || echo '?'); \
			flag=""; \
			[ "$$behind" -gt 20 ] 2>/dev/null && flag="  [STALE: rebase]"; \
			active=""; [ "$$name" = "$(ACTIVE)" ] && active="  <- active"; \
			echo "  $$name  ahead:$$ahead behind:$$behind$$flag$$active"; \
		fi; \
	done
	@if [ -n "$(ACTIVE)" ]; then echo "active: $(ACTIVE)"; else echo "active: (none - echo <name> > $(WORKTREES)/ACTIVE)"; fi

agent-%:
	@test -n "$(ACTIVE)" || { echo "no active playground: echo <name> > $(WORKTREES)/ACTIVE (or make agent-<t> ACTIVE=<name>)"; exit 1; }
	@test -d "$(WORKTREES)/$(ACTIVE)" || { echo "playground not found: $(WORKTREES)/$(ACTIVE) (git worktree add $(WORKTREES)/$(ACTIVE) -b agent/$(ACTIVE))"; exit 1; }
	$(MAKE) -C $(WORKTREES)/$(ACTIVE) $*

help:
	@echo "hildi targets:"
	@echo "  make                          build the example (debug)"
	@echo "  make test                     build & run the fpcunit suite"
	@echo "  make test SUITE=<name>        run one suite or test method"
	@echo "  make test-leak                run the suite under heaptrc (fails on leaks)"
	@echo "  make watch [TARGET=test-leak] auto-rerun on source changes"
	@echo "  make check                    all gates: test + test-leak"
	@echo "  make libsqlite                build vendored SQLite static archive"
	@echo "  make release                  build an optimized example"
	@echo "  make release-agent-cli        build the optimized, static CLI binary"
	@echo "  make tui-demo                 build & run the interactive TUI demonstration"
	@echo "  make widgets-demo             build & run the widget-kit demo"
	@echo "  make layout-demo              build & run the responsive two-column layout demo"
	@echo "  make headless-agent           build the headless session runtime (no TUI)"
	@echo "  make mcp-smoke                live MCP smoke against a real server (needs Docker)"
	@echo "  make agents                   list agent playgrounds (ahead/behind, stale flags)"
	@echo "  make agent-<target>           run <target> in the ACTIVE playground"
	@echo "  make async-standalone         build & run the Async Core isolation check"
	@echo "  make async-examples           build & run the three Async Core worked examples"
	@echo "  make tui-agent [ARGS=...]     build & run the agent harness (needs an API key)"
	@echo "  make bench [ARGS=--real]      build & run the TUI wall-clock benchmark"
	@echo "  make perf                     run the benchmark with budget assertions"
	@echo "  make smoke [SCENARIO=<name>]  live end-to-end smoke: fake provider + a real runtime"
	@echo "  make smoke-list               list the smoke scenarios"
	@echo "  make shell-ast [SCRIPT=...]   dump the shell parser's AST for a script"
	@echo "  make shell-flags              corpus tallies for the builtin tier's coverage"
	@echo "  make shell-standalone         build & run the shell library with no harness unit"
	@echo "  make changes-standalone       build & run the changes library with no harness unit"
	@echo "  make markdown-standalone      build & run the markdown library with no harness or tui unit"
	@echo "  make markdown-stream-demo     watch the streaming parser finalise blocks
	@echo "  make clean                    remove build artifacts"
