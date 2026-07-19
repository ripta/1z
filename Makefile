.PHONY: all branch-info build release run fmt test test-threads-1 test-threads-auto unit-test capi-test capi-release-run embed-stdlib-test integration-test lib-test eager-test fmt-test leak-goldens-check lsp-test tree-sitter-test contrib aot-test aot-run aot-interpreter-strip-check aot-line-directives-check aot-asm-name-check aot-string-literal-direct-check aot-symbol-literal-direct-check aot-trace-instr-check aot-trace-word-filter-check aot-symbol-verify aot-symbol-verify-linux bail-stats ir-check ir-check-upstream ir-vendor lua-vendor update-golden update-fmt-golden update-aot-golden update-lsp-golden benchmark benchmark-fib benchmark-quotation benchmark-ffi-gen-filter benchmark-word-resolution benchmark-protocol-dispatch benchmark-lint benchmark-tokenize benchmark-tokenize-alloc benchmark-expr benchmark-fn profiles build-example clean help docs docker-build docker-test freestanding-build baremetal-riscv64-test unit-coverage integration-coverage coverage

SHELL := /bin/bash
TARGET_TIMEOUT ?= 60
TEST_CASE_TIMEOUT ?= 10
AOT_TIMEOUT ?= 10

# AOT build steps compile C and are categorically heavier than test runs, so
# they get four times the per-case budget. The heaviest fixture (lint_driver_free)
# measured 22.3s in a fully uncached -j14 pass against 8s standalone.
AOT_BUILD_TIMEOUT ?= $(shell expr $(TEST_CASE_TIMEOUT) \* 4)
ZIG_PREFIX ?= zig-out
DOCKER_IMAGE ?= gcr.io/$(GCP_PROJECT_ID)/zag:v0.15.2
TEST_FILTER_ARG = $(if $(TEST_FILTER),-Dtest-filter=$(TEST_FILTER))

# Optional CPU target for the build. Empty selects the Zig default (baseline
# CPU for the native arch); set ZIG_CPU=native to enable host CPU features such
# as the SIMD paths inside std.mem.indexOf.
ZIG_CPU ?=
ZIG_CPU_ARG = $(if $(ZIG_CPU),-Dcpu=$(ZIG_CPU))

# Within each zig build invocation, the build runner parallelizes independent
# test steps automatically. JOBS controls the zig build runner thread count.
# Tests marked .serial=true in their .zon metadata, e.g., HTTP server tests,
# are chained to avoid port conflicts.
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
ZIG_JOBS_ARG = -j$(JOBS)

# Process-spawning test passes use >1 core per slot; size them to the P-core
# count to avoid saturation.
TEST_JOBS ?= $(shell sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)
ZIG_TEST_JOBS_ARG = -j$(TEST_JOBS)

# Using kcov for code coverage. kcov's ptrace tracing is flaky on macOS under
# heavy parallelism, so integration coverage runs at a reduced worker count and
# retries any crashed file serially; raise COVERAGE_JOBS on Linux where kcov is
# stable.
KCOV ?= kcov
COVERAGE_DIR ?= $(ZIG_PREFIX)/coverage
KCOV_ARGS ?= --include-path=src
COVERAGE_JOBS ?= 4

# mktemp inside $(shell ...) yields an empty string on failure and make keeps
# going, so a later `-o $(VAR)` would swallow the next argument as the output
# path. Abort the recipe instead.
mktemp_or_die = $(or $(shell mktemp $(1)),$(error mktemp failed for $(1)))

all: build test

branch-info: ## Print branch, HEAD, and describe before building/testing
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		echo "[git] $$(git rev-parse --abbrev-ref HEAD) @ $$(git rev-parse --short HEAD) ($$(git describe --tags --always --dirty))"; \
	else \
		echo "[git] not in a git repository"; \
	fi

build: branch-info ## Build the project (default)
	zig build --prefix $(ZIG_PREFIX) $(ZIG_CPU_ARG)

release: branch-info ## Build with optimizations
	zig build --release=fast --prefix $(ZIG_PREFIX) $(ZIG_CPU_ARG)

run: build ## Build and run the 1z interpreter
	./$(ZIG_PREFIX)/bin/1z $(ARGS)

fmt: build ## Format zig and 1z source files
	timeout $(TARGET_TIMEOUT) zig fmt src/ build.zig
	timeout $(TARGET_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z fmt $$(find . \( -path './.zig-cache' -o -path './$(ZIG_PREFIX)' \) -prune -o -name '*.1z' -print)

test: branch-info leak-goldens-check test-threads-1 test-threads-auto capi-test ## Run all tests under both --threads=1 and --threads=auto

leak-goldens-check: ## Fail if any test golden has baked-in GPA leak text
	@if grep -rl 'error(gpa)' tests/ --include='*.golden'; then \
		echo "FAIL: GPA leak text baked into the golden(s) above; a leaking test is being masked"; \
		exit 1; \
	fi
	@echo "PASS: no GPA leak text in golden files"

test-threads-1: ## Run all tests with default --threads=1 for integration tests
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)
	$(MAKE) embed-stdlib-test
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dtest-threads=1 $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dtest-threads=1 $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Daot-build-timeout=$(AOT_BUILD_TIMEOUT) $(TEST_FILTER_ARG)
	$(MAKE) lib-test

test-threads-auto: ## Run all tests with default --threads=auto for integration tests
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)
	$(MAKE) embed-stdlib-test
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dtest-threads=auto $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dtest-threads=auto $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Daot-build-timeout=$(AOT_BUILD_TIMEOUT) $(TEST_FILTER_ARG)
	$(MAKE) lib-test

unit-test: ## Run unit tests
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)

capi-test: ## Run hosted C-API embedding-library unit tests
	timeout $(TARGET_TIMEOUT) zig build capi-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dembed-stdlib=true

capi-release-run: ## Build the embedding example against a ReleaseFast lib1z and run it
	zig build --release=fast --prefix $(ZIG_PREFIX)/release $(ZIG_CPU_ARG)
	zig cc -o $(ZIG_PREFIX)/release/embed examples/embed.c -Iinclude $(ZIG_PREFIX)/release/clib/lib1z.a -lffi
	./$(ZIG_PREFIX)/release/embed

embed-stdlib-test: ## Run unit tests with -Dembed-stdlib=true
	timeout $(TARGET_TIMEOUT) zig build test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Dembed-stdlib=true

unit-coverage: ## Measure unit-test coverage with kcov (report under $(COVERAGE_DIR)/unit)
	zig build unit-test-bin --prefix $(ZIG_PREFIX) $(ZIG_CPU_ARG)
	rm -rf $(COVERAGE_DIR)/unit $(COVERAGE_DIR)/combined
	mkdir -p $(COVERAGE_DIR)/unit
	$(KCOV) $(KCOV_ARGS) $(COVERAGE_DIR)/unit ./$(ZIG_PREFIX)/test/1z-unit-test
	@pct=$$(grep -o '"percent_covered": "[0-9.]*"' $(COVERAGE_DIR)/unit/1z-unit-test/coverage.json | tail -1 | grep -o '[0-9.]*'); echo "Unit coverage: $${pct:-?}%, report at $(COVERAGE_DIR)/unit/index.html"

integration-coverage: build ## Measure integration + formatter + lib coverage with kcov (report under $(COVERAGE_DIR)/integration; honors TEST_FILTER)
	ONEZ=./$(ZIG_PREFIX)/bin/1z KCOV='$(KCOV)' KCOV_ARGS='$(KCOV_ARGS)' COVERAGE_DIR='$(COVERAGE_DIR)' JOBS=$(COVERAGE_JOBS) TEST_CASE_TIMEOUT=$(TEST_CASE_TIMEOUT) TEST_FILTER='$(TEST_FILTER)' scripts/coverage-integration.sh

coverage: unit-coverage integration-coverage ## Measure combined unit + integration coverage (report under $(COVERAGE_DIR)/combined)
	rm -rf $(COVERAGE_DIR)/combined
	$(KCOV) --merge $(COVERAGE_DIR)/combined $(COVERAGE_DIR)/unit $(COVERAGE_DIR)/integration
	@pct=$$(grep -o '"percent_covered": "[0-9.]*"' $(COVERAGE_DIR)/combined/kcov-merged/coverage.json | tail -1 | grep -o '[0-9.]*'); echo "Combined coverage (union of both): $${pct:-?}%, report at $(COVERAGE_DIR)/combined/index.html"

integration-test: ## Run integration tests
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

lib-test: build ## Run *_test.1z unit tests under lib/
	find lib -name '*_test.1z' -print0 | xargs -0 -P $(TEST_JOBS) -n 1 timeout $(TARGET_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z test

jit-build: ## Build only the 1z-jit binary
	timeout $(TIMEOUT) zig build jit-build --prefix $(ZIG_PREFIX)

jit-test: ## Run integration tests with JIT auto-compilation
	timeout $(TARGET_TIMEOUT) zig build integration-test --prefix $(ZIG_PREFIX) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT)

eager-test: ## Run integration tests with eager compilation
	timeout $(TARGET_TIMEOUT) zig build eager-integration-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

fmt-test: ## Run formatter tests
	timeout $(TARGET_TIMEOUT) zig build fmt-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

aot-run: build ## AOT-compile and run a 1z file (FILE= ARGS= AOT_TIMEOUT=10)
	$(eval _aot_tmp := $(call mktemp_or_die,/tmp/1z-aot-run-XXXXXX))
	@trap 'rm -f $(_aot_tmp)' EXIT; \
	timeout $(AOT_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z build $(FILE) -o $(_aot_tmp) $(ARGS) && \
	chmod +x $(_aot_tmp) && \
	timeout $(AOT_TIMEOUT) $(_aot_tmp)

aot-test: aot-interpreter-strip-check aot-line-directives-check aot-asm-name-check aot-string-literal-direct-check aot-symbol-literal-direct-check aot-trace-instr-check aot-trace-word-filter-check ## Run AOT build integration tests
	timeout $(TARGET_TIMEOUT) zig build aot-test --prefix $(ZIG_PREFIX) $(ZIG_TEST_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) -Daot-build-timeout=$(AOT_BUILD_TIMEOUT) $(TEST_FILTER_ARG)

aot-line-directives-check: build ## Verify AOT-emitted C carries `#line` directives at word and quotation function entries
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-line-directives-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-line-directives-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --save-temps -o $(_bin) tests/aot/aot_line_directives.1z 2>$(_stderr); \
	saved=$$(grep -m1 '^Saved: ' $(_stderr) | sed 's/^Saved: //'); \
	if [ -z "$$saved" ]; then \
		echo "FAIL: build did not report a saved C file (missing --save-temps output)"; \
		cat $(_stderr); exit 1; \
	fi; \
	trap "rm -f $(_bin) $(_stderr) $$saved" EXIT; \
	if ! grep -qE '^#line 6 "tests/aot/aot_line_directives.1z"' "$$saved"; then \
		echo "FAIL: missing #line for user-defined word 'double' (expected line 6)"; \
		grep '^#line.*aot_line_directives' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE '^#line 9 "tests/aot/aot_line_directives.1z"' "$$saved"; then \
		echo "FAIL: missing #line for inline quotation (expected line 9)"; \
		grep '^#line.*aot_line_directives' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE '^#line [0-9]+ "src/prelude.1z"' "$$saved"; then \
		echo "FAIL: missing #line for a prelude word (expected src/prelude.1z path)"; \
		grep '^#line.*prelude' "$$saved" | head -5 || true; exit 1; \
	fi; \
	abs_body=$$(awk '/^int32_t onez_w_abs\(uintptr_t jit_ctx\)$$/,/^\}/' "$$saved"); \
	if ! echo "$$abs_body" | grep -qE '^#line 16 "tests/aot/aot_line_directives.1z"'; then \
		echo "FAIL: missing #line 16 inside onez_w_abs (if-true arm body)"; \
		echo "$$abs_body" | grep '^#line' || true; exit 1; \
	fi; \
	if ! echo "$$abs_body" | grep -qE '^#line 17 "tests/aot/aot_line_directives.1z"'; then \
		echo "FAIL: missing #line 17 inside onez_w_abs (if-false arm body)"; \
		echo "$$abs_body" | grep '^#line' || true; exit 1; \
	fi; \
	entry_body=$$(awk '/^int32_t onez_w___entry__\(uintptr_t jit_ctx\)$$/,/^\}/' "$$saved"); \
	if ! echo "$$entry_body" | grep -qE '^#line 26 "tests/aot/aot_line_directives.1z"'; then \
		echo "FAIL: missing #line 26 inside onez_w___entry__ (multi-line loop body)"; \
		echo "$$entry_body" | grep '^#line' || true; exit 1; \
	fi; \
	echo "PASS: AOT-emitted C carries #line directives for user words, quotations, prelude, if arms, and loop bodies"

aot-trace-instr-check: build ## Verify --trace-aot=instr fires per-instruction for a non-recursive word and locates its NC.13
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-trace-instr-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-trace-instr-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	: 'TraceWriter re-creates a File.Writer per line, so a seekable stderr overwrites at offset 0; pipe stderr through cat to keep it non-seekable and preserve every line.'; \
	./$(ZIG_PREFIX)/bin/1z build tests/aot/aot_trace_instr.1z -o $(_bin) --interpreter-fallback=false --trace-aot=instr 2>&1 1>/dev/null | cat > $(_stderr) || true; \
	if ! grep -qE '^AOT instr bad-nonrec ' $(_stderr); then \
		echo "FAIL: --trace-aot=instr did not fire for the non-recursive word 'bad-nonrec'"; \
		grep -E '^AOT instr ' $(_stderr) | head -5 || true; exit 1; \
	fi; \
	if ! grep -qE '^AOT instr bad-nonrec op=call_word_direct target=drop sp=0 ' $(_stderr); then \
		echo "FAIL: instr trace did not locate the underflowing 'drop' at sp=0"; \
		grep -E '^AOT instr bad-nonrec ' $(_stderr) || true; exit 1; \
	fi; \
	if ! grep -qE "word 'bad-nonrec': NC.13" $(_stderr); then \
		echo "FAIL: build did not reject 'bad-nonrec' with NC.13"; \
		grep -E 'could not be compiled|NC\.' $(_stderr) || true; exit 1; \
	fi; \
	echo "PASS: --trace-aot=instr fires for a non-recursive word and locates its NC.13 underflow to an instruction"

aot-trace-word-filter-check: build ## Verify --trace-aot-word=PAT scopes the trace to matching words on a per-word and the instr axis
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-trace-word-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-trace-word-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	: 'TraceWriter re-creates a File.Writer per line, so a seekable stderr overwrites at offset 0; pipe stderr through cat to keep it non-seekable and preserve every line.'; \
	./$(ZIG_PREFIX)/bin/1z build tests/aot/aot_trace_word_filter.1z -o $(_bin) --interpreter-fallback=false --trace-aot=freeze --trace-aot-word=keep-me 2>&1 1>/dev/null | cat > $(_stderr) || true; \
	if ! grep -qE '^AOT freeze word keep-me ' $(_stderr); then \
		echo "FAIL: --trace-aot-word=keep-me dropped the freeze line for the matching word"; \
		grep -E '^AOT freeze word (keep-me|skip-me) ' $(_stderr) || true; exit 1; \
	fi; \
	if grep -qE '^AOT freeze word skip-me ' $(_stderr); then \
		echo "FAIL: --trace-aot-word=keep-me did not filter out the non-matching word skip-me on the freeze axis"; \
		grep -E '^AOT freeze word skip-me ' $(_stderr) || true; exit 1; \
	fi; \
	./$(ZIG_PREFIX)/bin/1z build tests/aot/aot_trace_word_filter.1z -o $(_bin) --interpreter-fallback=false --trace-aot=instr --trace-aot-word=keep-me 2>&1 1>/dev/null | cat > $(_stderr) || true; \
	if ! grep -qE '^AOT instr keep-me ' $(_stderr); then \
		echo "FAIL: --trace-aot-word=keep-me dropped the instr lines for the matching word"; \
		grep -E '^AOT instr (keep-me|skip-me) ' $(_stderr) | head -5 || true; exit 1; \
	fi; \
	if grep -qE '^AOT instr skip-me ' $(_stderr); then \
		echo "FAIL: --trace-aot-word=keep-me did not filter out the non-matching word skip-me on the instr axis"; \
		grep -E '^AOT instr skip-me ' $(_stderr) | head -5 || true; exit 1; \
	fi; \
	echo "PASS: --trace-aot-word=PAT scopes both a per-word axis and the instr firehose to the matching word"

aot-asm-name-check: build ## Verify AOT-emitted C carries `asm("...")` overrides so linker symbols show verbatim 1z names
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-asm-name-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-asm-name-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --save-temps -o $(_bin) tests/aot/aot_asm_names.1z 2>$(_stderr); \
	saved=$$(grep -m1 '^Saved: ' $(_stderr) | sed 's/^Saved: //'); \
	if [ -z "$$saved" ]; then \
		echo "FAIL: build did not report a saved C file (missing --save-temps output)"; \
		cat $(_stderr); exit 1; \
	fi; \
	trap "rm -f $(_bin) $(_stderr) $$saved" EXIT; \
	if ! grep -qE 'int32_t onez_w_parse_json_Q\(uintptr_t jit_ctx\) asm\("parse-json\?"\);' "$$saved"; then \
		echo "FAIL: missing asm-name clause for user-defined word 'parse-json?'"; \
		grep -E '^int32_t onez_w_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_w__Gfoo\(uintptr_t jit_ctx\) asm\(">foo"\);' "$$saved"; then \
		echo "FAIL: missing asm-name clause for user-defined word '>foo'"; \
		grep -E '^int32_t onez_w_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_w_print_line\(uintptr_t jit_ctx\) asm\("print-line"\);' "$$saved"; then \
		echo "FAIL: missing asm-name clause for prelude word 'print-line'"; \
		grep -E '^int32_t onez_w_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_q_[0-9]+\(uintptr_t jit_ctx\) asm\("pick-quot/quot@17:3"\);' "$$saved"; then \
		echo "FAIL: missing asm-name for compiled quotation pick-quot/quot@17:3"; \
		grep -E '^int32_t onez_q_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_q_[0-9]+\(uintptr_t jit_ctx\) asm\("pick-quot/quot@18:3"\);' "$$saved"; then \
		echo "FAIL: missing asm-name for compiled quotation pick-quot/quot@18:3"; \
		grep -E '^int32_t onez_q_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_q_[0-9]+\(uintptr_t jit_ctx\) asm\("flip/quot@25:18"\);' "$$saved"; then \
		echo "FAIL: missing asm-name for compiled quotation flip/quot@25:18 (same-line sibling)"; \
		grep -E '^int32_t onez_q_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_q_[0-9]+\(uintptr_t jit_ctx\) asm\("flip/quot@25:38"\);' "$$saved"; then \
		echo "FAIL: missing asm-name for compiled quotation flip/quot@25:38 (same-line sibling)"; \
		grep -E '^int32_t onez_q_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_w_serial_G_G\(uintptr_t jit_ctx\) asm\("person/serial>>"\);' "$$saved"; then \
		echo "FAIL: missing asm-name clause for struct field accessor 'person/serial>>'"; \
		grep -E '^int32_t onez_w_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! grep -qE 'int32_t onez_w_status_Q\(uintptr_t jit_ctx\) asm\("status/status\?"\);' "$$saved"; then \
		echo "FAIL: missing asm-name clause for enum aggregate predicate 'status/status?'"; \
		grep -E '^int32_t onez_w_.* asm\(' "$$saved" || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T parse-json\?$$'; then \
		echo "FAIL: nm did not report 'parse-json?' as a linker symbol"; \
		nm $(_bin) | grep -E ' T (parse-json|>foo|print-line)' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T >foo$$'; then \
		echo "FAIL: nm did not report '>foo' as a linker symbol"; \
		nm $(_bin) | grep -E ' T (parse-json|>foo|print-line)' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T print-line$$'; then \
		echo "FAIL: nm did not report 'print-line' as a linker symbol (prelude)"; \
		nm $(_bin) | grep -E ' T (parse-json|>foo|print-line)' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T pick-quot/quot@17:3$$'; then \
		echo "FAIL: nm did not report 'pick-quot/quot@17:3' as a linker symbol"; \
		nm $(_bin) | grep -E ' T (pick-quot|flip)/quot@' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T flip/quot@25:38$$'; then \
		echo "FAIL: nm did not report 'flip/quot@25:38' as a linker symbol"; \
		nm $(_bin) | grep -E ' T (pick-quot|flip)/quot@' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T person/serial>>$$'; then \
		echo "FAIL: nm did not report 'person/serial>>' as a linker symbol (struct field accessor)"; \
		nm $(_bin) | grep -E ' T (person|status)/' || true; exit 1; \
	fi; \
	if ! nm $(_bin) | grep -qE ' T status/status\?$$'; then \
		echo "FAIL: nm did not report 'status/status?' as a linker symbol (enum aggregate predicate)"; \
		nm $(_bin) | grep -E ' T (person|status)/' || true; exit 1; \
	fi; \
	echo "PASS: AOT-emitted C carries asm-name overrides for user words, prelude words, compiled quotations, and generated words; nm shows verbatim symbols"

aot-string-literal-direct-check: build ## Verify AOT string literals are constructed inline with no jitPushString trampoline or allocation
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-string-literal-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-string-literal-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --save-temps -o $(_bin) tests/aot/aot_string_literal_direct.1z 2>$(_stderr); \
	saved=$$(grep -m1 '^Saved: ' $(_stderr) | sed 's/^Saved: //'); \
	if [ -z "$$saved" ]; then \
		echo "FAIL: build did not report a saved C file (missing --save-temps output)"; \
		cat $(_stderr); exit 1; \
	fi; \
	trap "rm -f $(_bin) $(_stderr) $$saved" EXIT; \
	if ! grep -qE '\*\(\(uintptr_t\*\)d_[0-9]+\) = \(uintptr_t\)onez_lit_[0-9]+;' "$$saved"; then \
		echo "FAIL: emitted C does not construct a string literal slice pointer inline"; \
		grep -E 'onez_lit_[0-9]+;' "$$saved" || true; exit 1; \
	fi; \
	if grep -E 'onez_push_string\(' "$$saved" | grep -vq '^static int32_t onez_push_string'; then \
		echo "FAIL: emitted C still calls the onez_push_string trampoline for a string literal"; \
		grep -E 'onez_push_string\(' "$$saved" || true; exit 1; \
	fi; \
	echo "PASS: AOT string literals are constructed inline via ValueLayout offsets with no jitPushString trampoline"

aot-symbol-literal-direct-check: build ## Verify AOT symbol literals are constructed inline with no jitPushSymbol trampoline or allocation
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-symbol-literal-XXXXXX))
	$(eval _stderr := $(call mktemp_or_die,/tmp/1z-symbol-literal-stderr-XXXXXX))
	@trap 'rm -f $(_bin) $(_stderr)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --save-temps -o $(_bin) tests/aot/aot_symbol_literal_direct.1z 2>$(_stderr); \
	saved=$$(grep -m1 '^Saved: ' $(_stderr) | sed 's/^Saved: //'); \
	if [ -z "$$saved" ]; then \
		echo "FAIL: build did not report a saved C file (missing --save-temps output)"; \
		cat $(_stderr); exit 1; \
	fi; \
	trap "rm -f $(_bin) $(_stderr) $$saved" EXIT; \
	if ! grep -qE '\*\(\(uintptr_t\*\)d_[0-9]+\) = \(uintptr_t\)onez_lit_[0-9]+;' "$$saved"; then \
		echo "FAIL: emitted C does not construct a symbol literal slice pointer inline"; \
		grep -E 'onez_lit_[0-9]+;' "$$saved" || true; exit 1; \
	fi; \
	if grep -E 'onez_push_symbol\(' "$$saved" | grep -vq '^static int32_t onez_push_symbol'; then \
		echo "FAIL: emitted C still calls the onez_push_symbol trampoline for a symbol literal"; \
		grep -E 'onez_push_symbol\(' "$$saved" || true; exit 1; \
	fi; \
	echo "PASS: AOT symbol literals are constructed inline via ValueLayout offsets with no jitPushSymbol trampoline"

aot-symbol-verify: build ## Verify nm + samply + perf consume verbatim 1z names from AOT binaries
	$(eval _bin := $(call mktemp_or_die,/tmp/1z-symbol-verify-XXXXXX))
	$(eval _samply_profile := $(call mktemp_or_die,/tmp/1z-symbol-verify-samply-XXXXXX).json.gz)
	$(eval _samply_log := $(call mktemp_or_die,/tmp/1z-symbol-verify-samply-log-XXXXXX))
	$(eval _perf_data := $(call mktemp_or_die,/tmp/1z-symbol-verify-perf-XXXXXX))
	$(eval _perf_report := $(call mktemp_or_die,/tmp/1z-symbol-verify-perf-report-XXXXXX))
	@trap 'rm -f $(_bin) $(_samply_profile) $(_samply_profile).syms.json $(_samply_log) $(_perf_data) $(_perf_report)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build -o $(_bin) tests/aot/aot_symbol_verify_workload.1z > /dev/null 2>&1; \
	echo "--- nm ---"; \
	for name in 'parse-json?' '>foo' 'pick-quot'; do \
		if nm $(_bin) | awk -v n="$$name" '$$2=="T" && $$3==n {found=1} END {exit !found}'; then \
			echo "PASS nm: $$name present"; \
		else \
			echo "FAIL nm: $$name missing from symbol table"; exit 1; \
		fi; \
	done; \
	if nm $(_bin) | awk '$$2=="T" && $$3 ~ /\/quot@[0-9]+:[0-9]+$$/ {found=1} END {exit !found}'; then \
		echo "PASS nm: compiled-quotation /quot@<line>:<col> symbols preserved (Mach-O)"; \
	elif nm $(_bin) | awk '$$2=="T" && $$3 ~ /\/quot$$/ {found=1} END {exit !found}'; then \
		echo "NOTE nm: compiled-quotation symbols collapsed to bare /quot (ELF strips @<line>:<col> as version syntax)"; \
	else \
		echo "FAIL nm: no compiled-quotation symbols visible at all"; exit 1; \
	fi; \
	echo "--- samply ---"; \
	if command -v samply > /dev/null 2>&1; then \
		if samply record --unstable-presymbolicate --save-only --no-open -o $(_samply_profile) -- $(_bin) > $(_samply_log) 2>&1; then \
			syms="$(_samply_profile).syms.json"; \
			if [ ! -f "$$syms" ]; then \
				echo "FAIL samply: --unstable-presymbolicate did not emit $$syms"; \
				ls -lh $(_samply_profile)* || true; exit 1; \
			fi; \
			for name in 'parse-json?' '>foo' 'pick-quot'; do \
				if grep -qF "\"$$name\"" "$$syms"; then \
					echo "PASS samply: $$name present in syms sidecar"; \
				else \
					echo "FAIL samply: $$name missing from syms sidecar"; \
					grep -oE '"[A-Za-z>?_/<@:.0-9-]{4,40}"' "$$syms" | sort -u | head -20; \
					exit 1; \
				fi; \
			done; \
		else \
			rc=$$?; \
			echo "SKIP samply: record exited $$rc (likely missing entitlement on macOS or perf_event_paranoid on Linux)"; \
			tail -20 $(_samply_log) | sed 's/^/  /'; \
		fi; \
	else \
		echo "SKIP samply: not installed"; \
	fi; \
	echo "--- perf ---"; \
	if command -v perf > /dev/null 2>&1; then \
		if perf record -F 99 -g -o $(_perf_data) -- $(_bin) > /dev/null 2>&1; then \
			perf report --stdio --no-children -i $(_perf_data) > $(_perf_report) 2>&1; \
			for name in 'parse-json?' '>foo'; do \
				if grep -qF "$$name" $(_perf_report); then \
					echo "PASS perf: $$name present in report"; \
				else \
					echo "FAIL perf: $$name missing from report"; \
					head -50 $(_perf_report) | sed 's/^/  /'; exit 1; \
				fi; \
			done; \
		else \
			echo "SKIP perf: record failed (likely perf_event_paranoid restricts perf_event_open under Docker)"; \
		fi; \
	else \
		echo "SKIP perf: not installed (Linux-only)"; \
	fi; \
	echo "PASS: aot-symbol-verify"

aot-symbol-verify-linux: ## Run aot-symbol-verify inside the project's Debian Docker image
	docker build --build-arg BASE_IMAGE=gcr.io/$(GCP_PROJECT_ID)/zag:v0.15.2.1 --tag 1z-build:local .
	docker run --rm \
	    --security-opt seccomp=unconfined \
	    --cap-add SYS_ADMIN \
	    --volume $(CURDIR):/workspace \
	    --workdir /workspace \
	    --user 0:0 \
	    1z-build:local \
	    bash -c 'echo 1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true; make build && make aot-symbol-verify'

aot-interpreter-strip-check: build ## Verify linker GC strips the prelude loader from interpreter-free AOT binaries
	$(eval _free_bin := $(call mktemp_or_die,/tmp/1z-strip-check-free-XXXXXX))
	$(eval _linked_bin := $(call mktemp_or_die,/tmp/1z-strip-check-linked-XXXXXX))
	@trap 'rm -f $(_free_bin) $(_linked_bin)' EXIT; \
	./$(ZIG_PREFIX)/bin/1z build --interpreter-fallback=false --lock-interpreter-setting -o $(_free_bin) tests/aot/interpreter_free_lock_explicit.1z && \
	./$(ZIG_PREFIX)/bin/1z build --interpreter-fallback=true -o $(_linked_bin) tests/aot/interpreter_free_lock_explicit.1z && \
	if nm $(_free_bin) | grep -q '_onez_load_prelude'; then \
		echo "FAIL: interpreter-free binary still contains _onez_load_prelude (linker GC did not strip)"; exit 1; \
	fi; \
	if ! nm $(_linked_bin) | grep -q '_onez_load_prelude'; then \
		echo "FAIL: interpreter-linked binary missing _onez_load_prelude (build is broken or codegen mis-routed)"; exit 1; \
	fi; \
	free_size=$$(stat -f %z $(_free_bin) 2>/dev/null || stat -c %s $(_free_bin)); \
	linked_size=$$(stat -f %z $(_linked_bin) 2>/dev/null || stat -c %s $(_linked_bin)); \
	echo "PASS: _onez_load_prelude absent from interpreter-free, present in interpreter-linked"; \
	echo "      interpreter-free size:   $$free_size bytes"; \
	echo "      interpreter-linked size: $$linked_size bytes"; \
	echo "      delta:                   $$((linked_size - free_size)) bytes"; \
	free_inspect=$$(./$(ZIG_PREFIX)/bin/1z inspect $(_free_bin)); \
	linked_inspect=$$(./$(ZIG_PREFIX)/bin/1z inspect $(_linked_bin)); \
	if ! echo "$$free_inspect" | grep -q '^interpreter: linked=no, fallback=false, locked=yes$$'; then \
		echo "FAIL: 1z inspect on free binary did not report linked=no with fallback=false, locked=yes:"; \
		echo "$$free_inspect"; exit 1; \
	fi; \
	if ! echo "$$linked_inspect" | grep -q '^interpreter: linked=yes, fallback=true, locked=no$$'; then \
		echo "FAIL: 1z inspect on linked binary did not report linked=yes with fallback=true, locked=no:"; \
		echo "$$linked_inspect"; exit 1; \
	fi; \
	for required in '^1z-version: ' '^prelude-hash: '; do \
		if ! echo "$$free_inspect" | grep -q "$$required"; then \
			echo "FAIL: 1z inspect on free binary missing required row matching $$required"; \
			echo "$$free_inspect"; exit 1; \
		fi; \
		if ! echo "$$linked_inspect" | grep -q "$$required"; then \
			echo "FAIL: 1z inspect on linked binary missing required row matching $$required"; \
			echo "$$linked_inspect"; exit 1; \
		fi; \
	done; \
	echo "PASS: 1z inspect reports linked=no for interpreter-free, linked=yes for interpreter-linked"

bail-stats: ## Build with bail instrumentation and AOT-run a file (FILE=)
	zig build --prefix $(ZIG_PREFIX) -Dbail-stats=true
	$(eval _aot_tmp := $(call mktemp_or_die,/tmp/1z-bail-stats-XXXXXX))
	@trap 'rm -f $(_aot_tmp)' EXIT; \
	timeout $(AOT_TIMEOUT) ./$(ZIG_PREFIX)/bin/1z build $(FILE) -o $(_aot_tmp) && \
	chmod +x $(_aot_tmp) && \
	timeout $(AOT_TIMEOUT) $(_aot_tmp)

ir-check: ## Verify ext/ir/ matches pinned upstream plus patches/
	./ext/ir/check-local-patches.sh

ir-check-upstream: ## Also report whether ext/ir/ patches still apply at upstream HEAD
	CHECK_UPSTREAM_HEAD=1 ./ext/ir/check-local-patches.sh

ir-vendor: ## Re-vendor ext/ir/ (set IR_COMMIT=<sha> to bump the pin)
	IR_COMMIT=$(IR_COMMIT) ./ext/ir/vendor.sh

lua-vendor: ## Re-vendor ext/lua/ (set LUA_VERSION and LUA_SHA256 to bump the pin)
	./ext/lua/vendor.sh

lsp-test: ## Run LSP server tests
	timeout $(TARGET_TIMEOUT) zig build lsp-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) -Dtest-case-timeout=$(TEST_CASE_TIMEOUT) $(TEST_FILTER_ARG)

tree-sitter-test: ## Run tree-sitter grammar tests for contrib/tree-sitter/
	cd contrib/tree-sitter && npm test

contrib: tree-sitter-test ## Run all non-Zig contrib tooling checks (tree-sitter, and future additions)

update-golden: update-integration-golden update-aot-golden update-lsp-golden update-fmt-golden ## Update all golden files

update-aot-golden: ## Update AOT test golden files
	timeout $(TARGET_TIMEOUT) zig build update-aot-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-lsp-golden: ## Update LSP test golden files
	timeout $(TARGET_TIMEOUT) zig build update-lsp-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-integration-golden: ## Update integration test golden files
	timeout $(TARGET_TIMEOUT) zig build update-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

update-fmt-golden: ## Update formatter test golden files
	timeout $(TARGET_TIMEOUT) zig build update-fmt-golden --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG) $(TEST_FILTER_ARG)

BENCHMARK_FILES := $(wildcard tests/benchmark/*.1z)

benchmark-fib: build ## Run fibonacci benchmark across all execution modes
	@scripts/benchmark-fib.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/fibonacci_simple.1z $(ZIG_PREFIX)/benchmark-fib-aot

benchmark-quotation: build ## Run quotation sequence benchmark across all execution modes
	@scripts/benchmark-quotation.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/quotation_seq.1z $(ZIG_PREFIX)/benchmark-quotation-aot

benchmark-scanner: build ## Run scanner vs direct benchmark across interpreter modes
	@scripts/benchmark-scanner.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/scanner_vs_direct.1z

benchmark-word-resolution: build ## Run word-resolution benchmark across interpreter modes
	@scripts/benchmark-word-resolution.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/word_resolution.1z

benchmark-interpreter-suite: release ## Record the interpreter-dispatch representative-suite baseline
	@scripts/benchmark-interpreter-suite.sh ./$(ZIG_PREFIX)/bin/1z 7

benchmark-protocol-dispatch: build ## Build and run the protocol-bounded dispatch benchmark under runtime-image AOT
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/protocol_dispatch_aot.1z -o tests/benchmark/protocol_dispatch_aot.aot
	./tests/benchmark/protocol_dispatch_aot.aot > tests/benchmark/protocol_dispatch_aot.aot.sample

benchmark-lint: release ## Build the runtime-image AOT lint driver and time it against interpreted `1z lint`
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/lint_bench.1z -o tests/benchmark/lint_bench.aot
	@scripts/benchmark-lint.sh ./$(ZIG_PREFIX)/bin/1z tests/benchmark/lint_bench.aot \
		tests/integration/combinators.1z lib/data/json.1z > tests/benchmark/lint_bench.sample
	@cat tests/benchmark/lint_bench.sample

benchmark-tokenize: release ## Run the tokenizer scaling benchmark and record the linearity sample
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G tests/benchmark/bench_tokenize_scaling.1z > tests/benchmark/bench_tokenize_scaling.sample
	@cat tests/benchmark/bench_tokenize_scaling.sample

benchmark-tokenize-alloc: release ## Record the tokenizer per-token cost and allocation-attribution baseline
	./$(ZIG_PREFIX)/bin/1z run --benchmark --compile=off tests/benchmark/bench_tokenize_alloc.1z > tests/benchmark/bench_tokenize_alloc.sample
	./$(ZIG_PREFIX)/bin/1z run --benchmark=verbose --compile=off tests/benchmark/bench_tokenize_alloc.1z > tests/benchmark/bench_tokenize_alloc.benchmark.sample
	@cat tests/benchmark/bench_tokenize_alloc.sample

benchmark-char-interning: release ## Record the single-character string interning allocation comparison
	./$(ZIG_PREFIX)/bin/1z run --benchmark --compile=off tests/benchmark/bench_char_interning.1z > tests/benchmark/bench_char_interning.sample
	@cat tests/benchmark/bench_char_interning.sample

benchmark-tokenize-profile: release ## Record the tokenizer per-word time-attribution profile
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G --profile tests/benchmark/bench_tokenize_profile.1z > tests/benchmark/bench_tokenize_profile.profile.sample
	@cat tests/benchmark/bench_tokenize_profile.profile.sample

benchmark-expr: build ## Run the hosted expression pipeline benchmark and record the sample
	./$(ZIG_PREFIX)/bin/1z run tests/benchmark/expr_pipeline.1z > tests/benchmark/expr_pipeline.sample
	@cat tests/benchmark/expr_pipeline.sample

benchmark-fn: build ## Run the hosted function-definition benchmark and record the sample
	./$(ZIG_PREFIX)/bin/1z run tests/benchmark/fn_pipeline.1z > tests/benchmark/fn_pipeline.sample
	@cat tests/benchmark/fn_pipeline.sample

# NOTE(ripta): The focused split-based, index-based, flat (struct-free), and `while`-driven harnesses
#              build successfully with `--emit-runtime-image`. Their AOT runtime currently errors at
#              the first benchmark-auto call because run-benchmarks does not preserve stack state
#              across make-benchmark-report under `jitInterpretedCall`, so the `.aot.sample` captures
#              fall back to whatever stdout the binary emits before erroring (typically just the
#              timing header). The parent benchmark file additionally crashes at runtime under the
#              embedded runtime-image, so the parent build stays build-only.
benchmark-ffi-gen-filter: build ## Capture interpreter profiles and AOT timings for the ffi-gen filter variants on toy.h
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G --profile tests/benchmark/ffi_gen_filter_baseline.1z \
		> tests/benchmark/ffi_gen_filter_baseline.profile.sample
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G --profile tests/benchmark/ffi_gen_filter_index.1z \
		> tests/benchmark/ffi_gen_filter_index.profile.sample
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G --profile tests/benchmark/ffi_gen_filter_flat.1z \
		> tests/benchmark/ffi_gen_filter_flat.profile.sample
	./$(ZIG_PREFIX)/bin/1z run --max-memory=2G --profile tests/benchmark/ffi_gen_filter_while.1z \
		> tests/benchmark/ffi_gen_filter_while.profile.sample
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/ffi_gen_filter_baseline.1z -o tests/benchmark/ffi_gen_filter_baseline.aot
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/ffi_gen_filter_index.1z -o tests/benchmark/ffi_gen_filter_index.aot
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/ffi_gen_filter_flat.1z -o tests/benchmark/ffi_gen_filter_flat.aot
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/ffi_gen_filter_while.1z -o tests/benchmark/ffi_gen_filter_while.aot
	./$(ZIG_PREFIX)/bin/1z build --emit-runtime-image tests/benchmark/ffi_gen_filter.1z -o tests/benchmark/ffi_gen_filter.aot
	-./tests/benchmark/ffi_gen_filter_baseline.aot > tests/benchmark/ffi_gen_filter_baseline.aot.sample
	-./tests/benchmark/ffi_gen_filter_index.aot > tests/benchmark/ffi_gen_filter_index.aot.sample
	-./tests/benchmark/ffi_gen_filter_flat.aot > tests/benchmark/ffi_gen_filter_flat.aot.sample
	-./tests/benchmark/ffi_gen_filter_while.aot > tests/benchmark/ffi_gen_filter_while.aot.sample

benchmark: build ## Run benchmarks
	@for f in $(BENCHMARK_FILES); do echo "--- $$f ---"; ./$(ZIG_PREFIX)/bin/1z "$$f"; echo; done

PROFILE_FILES := $(wildcard tests/profiles/*.1z)

profiles: build ## Run profile sample workloads and refresh their .sample files
	@for f in $(PROFILE_FILES); do \
		echo "--- $$f ---"; \
		./$(ZIG_PREFIX)/bin/1z run --profile "$$f" > "$${f%.1z}.sample"; \
	done

build-example: build ## Build the C embedding example
	zig cc -o $(ZIG_PREFIX)/embed examples/embed.c -Iinclude $(ZIG_PREFIX)/clib/lib1z.a -lffi

freestanding-build: ## Compile-check the freestanding capi library for riscv64
	@echo "Building lib1z.a for riscv64-freestanding-none..."
	zig build --prefix $(ZIG_PREFIX)/freestanding-riscv64 -Dtarget=riscv64-freestanding-none --verbose install
	@if [ ! -f $(ZIG_PREFIX)/freestanding-riscv64/clib/lib1z.a ]; then \
		echo "FAIL: lib1z.a was not produced"; \
		exit 1; \
	fi
	@echo "Checking for banned host symbols..."
	@banned=$$(nm -u $(ZIG_PREFIX)/freestanding-riscv64/clib/lib1z.a 2>/dev/null | grep -E '(kqueue|epoll_create1|clock_gettime|dlopen|dlsym|getenv|selfExeDirPath)' || true); \
	if [ -n "$$banned" ]; then \
		echo "FAIL: freestanding lib1z.a references host-only symbols:"; \
		echo "$$banned"; \
		exit 1; \
	fi
	@echo "PASS: lib1z.a built for riscv64-freestanding-none with no host-only symbol references"

baremetal-riscv64-test: ## Build the riscv64 virt platform and AOT freestanding ELFs, then boot them under QEMU and compare serial output
	timeout $(TARGET_TIMEOUT) zig build baremetal-riscv64-test --prefix $(ZIG_PREFIX) $(ZIG_JOBS_ARG)
	scripts/baremetal-riscv64-test.sh $(ZIG_PREFIX)/baremetal/riscv64/1z-hello.elf tests/baremetal/riscv64/hello.serial.expected $(TARGET_TIMEOUT)
	scripts/baremetal-riscv64-test.sh $(ZIG_PREFIX)/baremetal/riscv64/1z-dispatch.elf tests/baremetal/riscv64/dispatch.serial.expected $(TARGET_TIMEOUT)

clean: ## Remove build artifacts
	mv .zig-cache .old.zig-cache
	rm -rf $(ZIG_PREFIX) .old.zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

docs: build ## Generate API reference documentation
	./$(ZIG_PREFIX)/bin/1z tools/gen-docs.1z

docker-build: ## Build the project inside Docker (Linux)
	docker build --build-arg GCP_PROJECT_ID=$(GCP_PROJECT_ID) -t gcr.io/$(GCP_PROJECT_ID)/1z .

docker-test: ## Run integration tests inside a Docker container
	docker run --rm gcr.io/$(GCP_PROJECT_ID)/1z make integration-test
