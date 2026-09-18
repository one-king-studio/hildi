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

# Vendored SQLite: built from deps/sqlite3 into build/lib (see scripts/fetch-sqlite.sh).
SQLITE_DIR    := deps/sqlite3
SQLITE_LIBDIR := $(BUILD)/lib
UNAME_S       := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SQLITE_LIB     := $(SQLITE_LIBDIR)/libsqlite3.dylib
SQLITE_CCFLAGS := -dynamiclib -O2 -DSQLITE_THREADSAFE=1
SQLITE_LDLIBS  := -lpthread
else
SQLITE_LIB     := $(SQLITE_LIBDIR)/libsqlite3.so
SQLITE_CCFLAGS := -shared -fPIC -O2 -DSQLITE_THREADSAFE=1
SQLITE_LDLIBS  := -lpthread -ldl
endif
CC ?= cc

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

TESTARGS := --format=plain
ifneq ($(SUITE),)
TESTARGS += --suite=$(SUITE)
else
TESTARGS += --all
endif

LIB_SRCS  := $(wildcard $(SRC)/*.pas)
TEST_SRCS := $(wildcard $(TESTS)/*.pas)

.PHONY: all test test-leak watch check release clean help libsqlite

all: $(BIN)/hildegard-helper-demo

# Build the vendored SQLite shared library; fetches the amalgamation if missing.
libsqlite: $(SQLITE_LIB)

$(SQLITE_LIB): $(SQLITE_DIR)/sqlite3.c
	@mkdir -p $(SQLITE_LIBDIR)
	$(CC) $(SQLITE_CCFLAGS) -o $@ $< $(SQLITE_LDLIBS)

$(SQLITE_DIR)/sqlite3.c:
	@scripts/fetch-sqlite.sh

store-demo: libsqlite $(BIN)/hildegard-helper-store-demo

$(BIN)/hildegard-helper-store-demo: $(EXAMPLES)/store_demo.pas $(LIB_SRCS) $(SQLITE_LIB)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

$(BIN)/hildegard-helper-demo: $(EXAMPLES)/demo_harness.pas $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test: libsqlite $(BIN)/hildegard-helper-tests
	$(BIN)/hildegard-helper-tests $(TESTARGS)

$(BIN)/hildegard-helper-tests: $(TESTS)/hildegard_helper_tests.pas $(TEST_SRCS) $(LIB_SRCS)
	@mkdir -p $(BIN) $(DBGUNITS)
	$(FPC) $(DEBUG) -Fu$(SRC) -Fu$(TESTS) -FU$(DBGUNITS) -FE$(BIN) -o$@ $<

test-leak: libsqlite $(BIN)/hildegard-helper-tests-leak
	HEAPTRC=$(HEAPTRC) $(BIN)/hildegard-helper-tests-leak $(TESTARGS)

# Auto-rerun TARGET (default: test) whenever sources change.
watch:
	@scripts/watch.sh $(TARGET)

$(BIN)/hildegard-helper-tests-leak: $(TESTS)/hildegard_helper_tests.pas $(TEST_SRCS) $(LIB_SRCS)
	@mkdir -p $(BIN) $(LEAKUNITS)
	$(FPC) $(LEAKFLAGS) -Fu$(SRC) -Fu$(TESTS) -FU$(LEAKUNITS) -FE$(BIN) -o$@ $<

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

help:
	@echo "hildegard-helper targets:"
	@echo "  make                          build the example (debug)"
	@echo "  make test                     build & run the fpcunit suite"
	@echo "  make test SUITE=<name>        run one suite or test method"
	@echo "  make test-leak                run the suite under heaptrc (fails on leaks)"
	@echo "  make watch [TARGET=test-leak] auto-rerun on source changes"
	@echo "  make check                    all gates: test + test-leak"
	@echo "  make libsqlite                build vendored SQLite shared library"
	@echo "  make release                  build an optimized example"
	@echo "  make clean                    remove build artifacts"
