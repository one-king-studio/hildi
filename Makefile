# hildegard-helper — developer Makefile
#
#   make            build the example (debug)
#   make test       build & run the fpcunit suite
#   make release    build an optimized example
#   make clean      remove build artifacts
#   make help       show this message

FPC      ?= fpc

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
else
SQLITE_CCFLAGS  := -O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5
MBEDTLS_CCFLAGS  := -O2 -fPIC
endif
# Link the static archive explicitly (-k), so a system libsqlite3 is never used.
SQLITE_LDFLAGS  := -k$(abspath $(SQLITE_AR))
CC ?= cc
AR ?= ar

# Vendored mbedTLS: compiled into STATIC archives and linked into the binaries
# that speak TLS, so no host OpenSSL is needed. See scripts/fetch-mbedtls.sh.
MBEDTLS_DIR       := deps/mbedtls
MBEDTLS_STAMP     := $(LIBSTATIC)/.mbedtls-built
MBEDTLS_AR        := $(LIBSTATIC)/libmbedtls.a
MBEDTLS_X509_AR   := $(LIBSTATIC)/libmbedx509.a
MBEDTLS_CRYPTO_AR := $(LIBSTATIC)/libmbedcrypto.a
TLS_SHIM_OBJ      := $(LIBSTATIC)/hildegard_tls_shim.o
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

# Language and strictness. -Sew turns warnings into hard errors.
MODE      := -Mdelphi -Sh
STRICT    := -vw -Sew
DEBUG     := $(MODE) $(STRICT) -O- -Crtio -Sa -gl
RELEASE   := $(MODE) $(STRICT) -O2 -CX -XX -Xs
# -gh links heaptrc into the test binary for leak checking.
LEAKFLAGS := $(MODE) $(STRICT) -O- -Crtio -Sa -gh -gl
# heaptrc: exit 203 if anything is still allocated; stay quiet when clean.
HEAPTRC   := haltonnotreleased:skipifnoleaks

# TDD knobs:
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
TEST_SRCS := $(wildcard $(TESTS)/*.pas)

.PHONY: all test test-leak watch check release clean help libsqlite libmbedtls \
        store-demo agent-cli release-agent-cli tui-demo widgets-demo layout-demo \
        headless-agent tui-agent bench perf agents agent-% mcp-smoke async-standalone async-bench

all: $(BIN)/hildegard-helper-demo

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

$(TLS_SHIM_OBJ): $(SRC)/hildegard_tls_shim.c $(SRC)/hildegard_tls_shim.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -c -o $@ $(SRC)/hildegard_tls_shim.c

$(CACERT_PEM):
	@scripts/fetch-cacert.sh

$(CACERT_GEN_C): $(CACERT_PEM) scripts/gen-cacert-embed.sh
	@scripts/gen-cacert-embed.sh

$(CACERT_OBJ): $(CACERT_GEN_C) $(SRC)/hildegard_tls_shim.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -c -o $@ $(CACERT_GEN_C)

# Test-only mbedTLS echo server; compiled into the test binaries only.
$(TLS_TEST_SERVER_OBJ): $(TESTS)/tls_test_server.c $(TESTS)/tls_test_server.h
	@mkdir -p $(LIBSTATIC)
	$(CC) $(TLS_CCFLAGS) -I$(TESTS) -c -o $@ $(TESTS)/tls_test_server.c

store-demo: libsqlite $(BIN)/hildegard-helper-store-demo

$(BIN)/hildegard-helper-store-demo: $(EXAMPLES)/store_demo.pas $(LIB_SRCS) $(SQLITE_AR)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

agent-cli: libsqlite libmbedtls $(BIN)/hildegard-helper-agent-cli

$(BIN)/hildegard-helper-agent-cli: $(EXAMPLES)/agent_cli.pas $(LIB_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Live MCP calibration smoke: drives the MCP client against a real MCP server
# (the Playwright container over docker stdio). Needs Docker; not part of
# `make check` (the suite is hermetic). See examples/mcp_smoke.pas.
mcp-smoke: libsqlite libmbedtls $(BIN)/mcp-smoke
	$(BIN)/mcp-smoke

$(BIN)/mcp-smoke: $(EXAMPLES)/mcp_smoke.pas $(LIB_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Optimized, self-contained production binary (static SQLite, no runtime libs).
release-agent-cli: libsqlite libmbedtls $(BIN)/hildegard-helper-agent-cli-release

$(BIN)/hildegard-helper-agent-cli-release: $(EXAMPLES)/agent_cli.pas $(LIB_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(RELEASE) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) -Fu$(SRC) -FU$(RELUNITS) -FE$(BIN) -o$@ $<

$(BIN)/hildegard-helper-demo: $(EXAMPLES)/demo_harness.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Interactive TUI demonstration: build, then run it in the terminal.
tui-demo: $(BIN)/hildegard-helper-tui-demo
	$(BIN)/hildegard-helper-tui-demo

$(BIN)/hildegard-helper-tui-demo: $(EXAMPLES)/tui_demo.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Widget-kit demo: a list, a preview panel, and focusable buttons. Builds and
# runs; Tab/Shift-Tab or click to focus, Enter/Space to activate, q to quit.
widgets-demo: $(BIN)/hildegard-helper-tui-widgets-demo
	$(BIN)/hildegard-helper-tui-widgets-demo

$(BIN)/hildegard-helper-tui-widgets-demo: $(EXAMPLES)/tui_widgets_demo.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Layout exploration: a responsive two-column harness layout (files + editor |
# chat column). The chat column has an optional side panel and a persistent
# bottom input panel. The split appears only when the terminal is wider than 180
# columns; Ctrl-B toggles the side panel, Ctrl-C quits.
layout-demo: $(BIN)/hildegard-helper-tui-layout-demo
	$(BIN)/hildegard-helper-tui-layout-demo

$(BIN)/hildegard-helper-tui-layout-demo: $(EXAMPLES)/tui_layout_demo.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Headless agent: hosts a session's runtime; spawned detached by the TUI or the
# CLI. No terminal. A client finds it as a sibling (or via HILDEGARD_RUNTIME_BIN).
headless-agent: libsqlite libmbedtls $(BIN)/hildegard-helper-agent

$(BIN)/hildegard-helper-agent: $(EXAMPLES)/headless_agent.pas $(LIB_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Full-screen agent harness (conversation + approvals + sessions). Builds and
# runs; Ctrl-C quits. Drives the headless agent.
tui-agent: headless-agent $(BIN)/hildegard-helper-tui
	$(BIN)/hildegard-helper-tui $(ARGS)

$(BIN)/hildegard-helper-tui: $(EXAMPLES)/tui_agent.pas $(LIB_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) $(TLS_LDFLAGS) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

# Printable wall-clock benchmark. `make bench ARGS=--real` measures the real
# terminal; `make perf` asserts the budgets and is not part of `make check`.
bench: $(BIN)/hildegard-helper-tui-bench
	$(BIN)/hildegard-helper-tui-bench $(ARGS)

perf: $(BIN)/hildegard-helper-tui-bench
	$(BIN)/hildegard-helper-tui-bench --assert

$(BIN)/hildegard-helper-tui-bench: $(EXAMPLES)/tui_bench.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test: libsqlite libmbedtls $(BIN)/hildegard-helper-tests
	$(BIN)/hildegard-helper-tests $(TESTARGS)

# The isolation gate: build a program that uses ONLY the async library, with no
# harness unit on the path. If the library ever depends on the harness, this
# fails to compile - which is what keeps it extractable.
async-standalone: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC)/async -FU$(DBGUNITS) -FE$(BIN) -o$(BIN)/async-standalone $(EXAMPLES)/async_standalone.pas

# A release build of the Async Core throughput benchmark.
async-bench: $(ASYNC_SRCS)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(RELEASE) -Fu$(SRC)/async -FU$(RELUNITS) -FE$(BIN) -o$(BIN)/async-bench $(EXAMPLES)/async_bench.pas
	$(BIN)/async-bench

$(BIN)/hildegard-helper-tests: $(TESTS)/hildegard_helper_tests.pas $(TEST_SRCS) $(LIB_SRCS) $(ASYNC_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ) $(TLS_TEST_SERVER_OBJ)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) $(SQLITE_LDFLAGS) -k$(abspath $(TLS_TEST_SERVER_OBJ)) $(TLS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/async -Fu$(TESTS) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test-leak: libsqlite libmbedtls $(BIN)/hildegard-helper-tests-leak
	HEAPTRC=$(HEAPTRC) $(BIN)/hildegard-helper-tests-leak $(TESTARGS)

# Auto-rerun TARGET (default: test) whenever sources change.
watch:
	@scripts/watch.sh $(TARGET)

$(BIN)/hildegard-helper-tests-leak: $(TESTS)/hildegard_helper_tests.pas $(TEST_SRCS) $(LIB_SRCS) $(ASYNC_SRCS) $(SQLITE_AR) $(MBEDTLS_STAMP) $(TLS_SHIM_OBJ) $(CACERT_OBJ) $(TLS_TEST_SERVER_OBJ)
	@mkdir -p $(BIN) $(LEAKUNITS)
	$(FPC) $(LEAKFLAGS) $(SQLITE_LDFLAGS) -k$(abspath $(TLS_TEST_SERVER_OBJ)) $(TLS_LDFLAGS) -Fu$(SRC) -Fu$(SRC)/async -Fu$(TESTS) -FU$(LEAKUNITS) -FE$(BIN) -o$@ $<

# All quality gates, for CI: functional tests + leak check.
check: test test-leak

release: $(BIN)/hildegard-helper-demo-release

$(BIN)/hildegard-helper-demo-release: $(EXAMPLES)/demo_harness.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(RELUNITS)
	$(FPC) $(RELEASE) -Fu$(SRC) -FU$(RELUNITS) -FE$(BIN) -o$@ $<

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
	@echo "hildegard-helper targets:"
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
	@echo "  make tui-agent [ARGS=...]     build & run the agent harness (needs an API key)"
	@echo "  make bench [ARGS=--real]      build & run the TUI wall-clock benchmark"
	@echo "  make perf                     run the benchmark with budget assertions"
	@echo "  make clean                    remove build artifacts"
