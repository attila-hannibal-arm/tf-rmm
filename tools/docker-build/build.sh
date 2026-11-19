#!/bin/bash

# SPDX-License-Identifier: BSD-3-Clause
# SPDX-FileCopyrightText: Copyright TF-RMM Contributors.

set -o pipefail

show_help() {
	cat <<'EOF'
Usage: build.sh [OPTIONS]
       docker compose run --rm rmm-builder [OPTIONS]

With no options, configure and build the fake-host platform.

Options:
  -h, --help                  Show this help and exit.
  --debug                     Configure a Debug build.
  --skip-build                Skip the initial configure/build (fuzz builds still run).
  --test                      Build and run host unit tests.
  --valgrind                  Run host unit tests under Valgrind (implies --test).
  --coverage                  Enable coverage; generate a report after unit tests.
  --fuzz                      Build and run AFL++ fuzzing.
  --fuzz-valgrind             Fuzz with every execution under Valgrind.
  --fuzz-valgrind-selective   Fuzz normally; replay saved inputs under Valgrind.
  --dry-run                   Parse options and exit without building or running tests.
  --show-summary DIR          Summarize existing Valgrind logs (implies --dry-run).

Environment settings (.env is loaded into the container by Docker Compose):
  RUN_BUILD                   yes/no; initial configure/build (default: yes).
  DEBUG                       yes/no; --debug (default: no).
  RUN_TESTS                   yes/no; --test (default: no).
  RUN_VALGRIND                yes/no; --valgrind (default: no).
  RUN_COVERAGE                yes/no; --coverage (default: no).
  RUN_FUZZ                    yes/no; --fuzz (default: no).
  RUN_FUZZ_VALGRIND           yes/no; --fuzz-valgrind (default: no).
  RUN_FUZZ_VALGRIND_SELECTIVE yes/no; --fuzz-valgrind-selective (default: no).
  DRY_RUN                     yes/no; --dry-run (default: no).
  SHOW_SUMMARY                Directory for --show-summary (default: empty).
  RMM_ARCH                    Initial build architecture (default: fake_host).
  RMM_SOURCE_DIR              Container source path (default: /workspace/tf-rmm).
  RMM_BUILD_DIR               In Compose .env: host build directory, absolute or
                              relative to tools/docker-build/ (required).
                              Mounted at /workspace/rmm-build.
                              For direct script use: build output path.
  FUZZ_DURATION_SECONDS       AFL++ duration in seconds (default: 1000).
  FUZZ_TIMEOUT_MS             Native AFL++ testcase timeout in ms (default: 1000).
  FUZZ_VALGRIND_TIMEOUT_MS    Valgrind testcase timeout in ms (default: 10000).
  FUZZ_MEMORY_LIMIT           AFL++ memory limit, MB or none (default: none).
  FUZZ_INPUT_FORMAT           AFL++ input format, -a (default: binary).
  FUZZ_STRATEGY               AFL++ strategy, -P (default: exploit).
  FUZZ_SCHEDULE               AFL++ schedule, -p (default: mmopt).
  FUZZ_POLL_INTERVAL_SECONDS  Idle queue polling interval (default: 0.5).
  FUZZ_PROGRESS_INTERVAL_SECONDS
                              Post-AFL++ progress interval (default: 5).
  FUZZ_BUILD_JOBS             Fuzz build parallel jobs (default: half the CPUs,
                              rounded down, minimum 1).
  FUZZ_VENV_DIR               Python environment (default: /workspace/fuzzenv).

Downstream tool environment variables are also passed through from .env:
  AFL_NO_UI                   Set to 1 to disable the AFL++ UI.
  AFL_FORCE_UI                Set to 1 to force the AFL++ UI.
                              Otherwise the wrapper enables it on a terminal.
  AFL_AUTORESUME              Normal fuzz resume setting (default: 1).
  AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES
                              AFL++ crash-reporting override (image default: 1).
  CMAKE_BUILD_PARALLEL_LEVEL  Parallelism for builds without an explicit -j.
  CC, CXX, CFLAGS, CXXFLAGS, LDFLAGS
                              Toolchain defaults, subject to CMake/toolchain settings.
  PIP_INDEX_URL, PIP_EXTRA_INDEX_URL, PIP_CACHE_DIR
                              pip package sources and cache location.
  Other AFL_*, CMAKE_*, and PIP_* variables follow the respective tool's rules.

CLI switches override their environment defaults. Use yes/no for run switches.
Other paths are container paths; changing them requires matching volume mounts.
The wrapper fixes AFL_SKIP_BIN_CHECK=1, AFL_NO_FORKSRV=1,
AFL_CRASH_EXITCODE=99, and AFL_KILL_SIGNAL=15 in full Valgrind mode because
its launcher, error detection, and shutdown depend on those values.

Select one fuzzing mode. Selective mode drains pending replays after AFL++ exits,
so total runtime may exceed FUZZ_DURATION_SECONDS. Ctrl+C stops replays and
prints the collected Valgrind summary.
EOF
}

# Keep access to the terminal even when fuzzing output is piped through tee.
TERMINAL_STATE=""
if { exec {TERMINAL_FD}<>/dev/tty; } 2>/dev/null; then
	TERMINAL_STATE=$(stty -g <&"$TERMINAL_FD" 2>/dev/null)
fi

restore_terminal() {
	if [[ -n "$TERMINAL_STATE" ]]; then
		stty "$TERMINAL_STATE" <&"$TERMINAL_FD" 2>/dev/null
		# AFL++ can also leave the cursor hidden and text attributes set.
		printf '\033[0m\033[?25h' >&"$TERMINAL_FD"
	fi
}

finish_run() {
	local status=$?
	trap '' INT TERM
	if [[ -n ${FUZZ_PID:-} ]]; then
		kill -TERM "$FUZZ_PID" 2>/dev/null
		wait "$FUZZ_PID" 2>/dev/null
	fi
	if [[ -n ${FUZZ_LOG_FD:-} ]]; then
		exec {FUZZ_LOG_FD}>&-
		wait "$FUZZ_TEE_PID" 2>/dev/null
	fi
	restore_terminal
	if [[ -n ${FUZZ_LOGDIR:-} && -d "$FUZZ_LOGDIR" ]]; then
		run_logged "${LOGDIR}/valgrind-summary.log" show_valgrind_summary "$FUZZ_LOGDIR"
	fi
	return "$status"
}

trap finish_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

OPTS=""
RUN_TESTS="${RUN_TESTS:-no}"
RUN_VALGRIND="${RUN_VALGRIND:-no}"
RUN_COVERAGE="${RUN_COVERAGE:-no}"
RUN_FUZZ="${RUN_FUZZ:-no}"
RUN_FUZZ_VALGRIND="${RUN_FUZZ_VALGRIND:-no}"
RUN_FUZZ_VALGRIND_SELECTIVE="${RUN_FUZZ_VALGRIND_SELECTIVE:-no}"
RUN_BUILD="${RUN_BUILD:-yes}"
DEBUG="${DEBUG:-no}"
DRY_RUN="${DRY_RUN:-no}"
SHOW_SUMMARY="${SHOW_SUMMARY:-}"
RMM_ARCH="${RMM_ARCH:-fake_host}"

while [[ $# -ge 1 ]]; do
	case "$1" in
		"--help"|"-h")
			show_help
			exit 0
		;;
		"--dry-run")
			DRY_RUN="yes"
		;;
		"--show-summary")
			if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
				echo "--show-summary requires a log directory" >&2
				exit 2
			fi
			SHOW_SUMMARY="$2"
			DRY_RUN="yes"
			shift
		;;
		"--fuzz-valgrind-selective")
			RUN_FUZZ="yes"
			RUN_FUZZ_VALGRIND_SELECTIVE="yes"
		;;
		"--fuzz-valgrind")
			RUN_FUZZ="yes"
			RUN_FUZZ_VALGRIND="yes"
		;;
		"--fuzz")
			RUN_FUZZ="yes"
		;;
		"--skip-build")
			RUN_BUILD="no"
		;;
		"--debug")
			DEBUG="yes"
		;;
		"--test")
			RUN_TESTS="yes"
		;;
		"--valgrind")
			RUN_VALGRIND="yes"
			RUN_TESTS="yes"
		;;
		"--coverage")
			RUN_COVERAGE="yes"
		;;
	esac
	shift
done

# Apply dependencies and CMake options after both environment and CLI processing.
[[ $RUN_VALGRIND == yes ]] && RUN_TESTS=yes
if [[ $RUN_FUZZ_VALGRIND == yes || $RUN_FUZZ_VALGRIND_SELECTIVE == yes ]]; then
	RUN_FUZZ=yes
fi
[[ -n $SHOW_SUMMARY ]] && DRY_RUN=yes
[[ $DEBUG == yes ]] && OPTS="-DCMAKE_BUILD_TYPE=Debug ${OPTS}"
[[ $RUN_TESTS == yes ]] && OPTS="-DHOST_VARIANT=host_test ${OPTS}"
[[ $RUN_VALGRIND == yes ]] && OPTS="-DCPPUTEST_MEM_LEAK_DETECTION_DISABLED=ON ${OPTS}"
[[ $RUN_COVERAGE == yes ]] && OPTS="-DRMM_COVERAGE=ON ${OPTS}"

show_valgrind_summary() {
	local path="$1" log_file item digest
	local count=0 distinct=0
	local -A seen=()

	echo "Valgrind summary: $path"
	if [[ ! -d "$path" ]]; then
		echo "No Valgrind logs found."
		return 0
	fi
	while IFS= read -r -d '' log_file; do
		((count += 1))
		# Ignore per-process headers and allocation totals when comparing logs.
		item=$(sed -E \
			-e 's/^==[0-9]+== ?//' \
			-e '/^Command: /d' \
			-e '/^Parent PID:/d' \
			-e '/total heap usage/d' "$log_file") || return 1
		digest=$(printf '%s' "$item" | sha256sum) || return 1
		digest=${digest%% *}
		[[ -z ${seen[$digest]:-} ]] || continue
		seen[$digest]=true
		((distinct += 1))
		printf '\n === DISTINCT USE CASE: %s === \n' "$log_file"
		cat -- "$log_file"
		echo " === END OF USE CASE === "
	done < <(find "$path" -type f -name '*.log' -print0)
	echo "Valgrind: $count logs, $distinct distinct reports."
}

if [[ $DRY_RUN == "yes" ]]; then
	if [[ -n "$SHOW_SUMMARY" ]]; then
		show_valgrind_summary "$SHOW_SUMMARY" || exit $?
	fi
	exit 0
fi

echo "Performing build"
LOG_ROOT="${RMM_BUILD_DIR}/logs"
mkdir -p "${LOG_ROOT}" || exit 1
LOGDIR=$(mktemp -d "${LOG_ROOT}/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || exit 1
echo "Run logs: ${LOGDIR}"
echo "CTest reports: ${RMM_BUILD_DIR}/Testing"

# Merge stdout/stderr in chronological order while keeping terminal output.
run_logged() {
	local log_file="$1"
	shift
	"$@" 2>&1 | tee "${log_file}"
}

# Wait on an explicit PID so signals interrupt the wait and EXIT can stop it.
run_fuzz_logged() {
	local log_file="$1" status tee_status
	shift
	exec {FUZZ_LOG_FD}> >(tee "$log_file")
	FUZZ_TEE_PID=$!
	"$@" >&"$FUZZ_LOG_FD" 2>&1 &
	FUZZ_PID=$!
	wait "$FUZZ_PID"
	status=$?
	FUZZ_PID=""
	exec {FUZZ_LOG_FD}>&-
	FUZZ_LOG_FD=""
	wait "$FUZZ_TEE_PID"
	tee_status=$?
	((status == 0)) || return "$status"
	return "$tee_status"
}

if [[ $RUN_BUILD == "yes" ]]; then
	echo "Building RMM"
	run_logged "${LOGDIR}/configure.log" cmake -DRMM_CONFIG=host_defcfg ${OPTS} \
		-DRMM_ARCH="${RMM_ARCH}" -S "${RMM_SOURCE_DIR}" -B "${RMM_BUILD_DIR}" || exit $?
	echo "RMM built"
else
	echo "Skipping RMM building"
fi

SP=('△' '▷' '▽' '◁')


if [[ $RUN_TESTS == "no" ]]; then
	if [[ $RUN_BUILD == "yes" ]]; then
		run_logged "${LOGDIR}/build.log" cmake --build "${RMM_BUILD_DIR}" || exit $?
	else
		echo "Skipping build."
	fi
else
	echo "Running tests..."
	if [[ $RUN_VALGRIND == "no" ]]; then
		cmake --build ${RMM_BUILD_DIR} -- run-unittests >"${LOGDIR}/tests.log" 2>&1 &
		TEST_PID=$!
	else
		cmake --build ${RMM_BUILD_DIR} -- run-unittests-memcheck >"${LOGDIR}/tests.log" 2>&1 &
		TEST_PID=$!
	fi
	TV=""
	row=0
	dc=0
	declare -A tcs
	tail -n +1 -f --pid="$TEST_PID" "${LOGDIR}/tests.log" | while IFS= read -r line; do
		if [[ "$line" =~ ([[:digit:]]+)/([[:digit:]]+)\ .*[^:]*:\ ([^ ]*)\ \.+\ *([^\ ]*)\ *([[:digit:]].*) ]]; then
			current=${BASH_REMATCH[1]}
			total=${BASH_REMATCH[2]}
			name=${BASH_REMATCH[3]}
			result=${BASH_REMATCH[4]}
			time=${BASH_REMATCH[5]}
			if [[ "$result" == "Passed" ]]; then
				TV="${TV}\e[0;92m✓"
				tcs[$current]=1
			elif [[ "$result" == "Defects:" ]]; then
				if [[ ${tcs[$current]} -gt 0 ]]; then
					tcs[$current]=2
				fi
				continue
			else
				tcs[$current]=-1
				echo -ne "\r"
				for i in $(seq 0 $total); do echo -n " "; done
				echo
				echo "Failed test #${current}: $name"
				echo
				TV="${TV}\e[0;91m𐄂"
			fi
			echo -ne "${TV}\e[0;96m"
			for i in $(seq $((current + 1)) $total); do echo -n ?; done
			echo -ne "\e[0m\r"
		else
			row=$(((row + 1) % ${#SP[@]}))
			echo -ne "${TV}\e[0;93m"
			echo -ne "${SP[row]}\e[0m\r"
		fi
	done
	echo
	wait "${TEST_PID}"
	TEST_STATUS=$?
	grep -A1000 "tests passed, .* tests failed out of" "${LOGDIR}/tests.log"
	[[ $TEST_STATUS -eq 0 ]] || exit "$TEST_STATUS"
	if [[ $RUN_COVERAGE == "yes" ]]; then
		run_logged "${LOGDIR}/coverage.log" cmake --build "${RMM_BUILD_DIR}" --target run-coverage || exit $?
	fi
	echo "Testing complete"
fi

if [[ $RUN_FUZZ == "yes" ]]; then
	FUZZ_STATUS=0
	# tee hides the terminal from AFL++; restore the UI for interactive runs.
	# Honor an explicit AFL_NO_UI setting and keep batch logs plain.
	if [[ -t 1 && -z ${AFL_NO_UI:-} ]]; then
		export AFL_FORCE_UI=1
	fi
	echo "Preparing fuzz build..."
	run_logged "${LOGDIR}/fuzz-venv.log" python3 -m venv "${FUZZ_VENV_DIR:-/workspace/fuzzenv}" || exit $?
	source "${FUZZ_VENV_DIR:-/workspace/fuzzenv}/bin/activate" || exit 1
	run_logged "${LOGDIR}/fuzz-dependencies.log" "${FUZZ_VENV_DIR:-/workspace/fuzzenv}/bin/pip" install \
		-r "${RMM_SOURCE_DIR}/tools/fuzz/python/requirements.txt" || exit 1
	source "${RMM_SOURCE_DIR}/tools/fuzz/fuzz.env" || exit 1

	if [[ $RUN_FUZZ_VALGRIND_SELECTIVE == "yes" ]]; then
		FUZZ_BUILD="${RMM_BUILD_DIR}/Fuzz/builds/docker-fuzz-selective"
		FUZZ_OUT="${RMM_BUILD_DIR}/Fuzz/aflout/docker-fuzz-selective"
		FUZZ_LOGDIR="${LOGDIR}/valgrind"
		(set -o pipefail; fuzzbuild 0 docker-fuzz-selective np) 2>&1 | tee "${LOGDIR}/fuzz-build.log" || exit $?
		run_logged "${LOGDIR}/fuzz-build-check.log" cmake --build "${FUZZ_BUILD}" || exit $?
		[[ -s "${FUZZ_BUILD}/smc_corpus/default.bin" ]] || exit 1
		echo "Starting selective Valgrind fuzzing; reports: ${FUZZ_LOGDIR}"
		run_fuzz_logged "${LOGDIR}/afl.log" run_selective_valgrind \
			"${FUZZ_OUT}/default" "${FUZZ_LOGDIR}" "${FUZZ_BUILD}/Debug/rmm.elf" \
			"${FUZZ_VALGRIND_TIMEOUT_MS:-10000}" \
			afl-fuzz -i "${FUZZ_BUILD}/smc_corpus" -o "${FUZZ_OUT}" \
			-V "${FUZZ_DURATION_SECONDS:-1000}" -t "${FUZZ_TIMEOUT_MS:-1000}" -m "${FUZZ_MEMORY_LIMIT:-none}" \
			-a "${FUZZ_INPUT_FORMAT:-binary}" -P "${FUZZ_STRATEGY:-exploit}" -p "${FUZZ_SCHEDULE:-mmopt}" -- "${FUZZ_BUILD}/Debug/rmm.elf" @@ || FUZZ_STATUS=$?
	elif [[ $RUN_FUZZ_VALGRIND == "yes" ]]; then
		# File input and a fresh process per testcase are required here.
		FUZZ_BUILD="${RMM_BUILD_DIR}/Fuzz/builds/docker-fuzz-valgrind"
		FUZZ_LOGDIR="${LOGDIR}/valgrind"
		mkdir -p "${FUZZ_LOGDIR}" || exit 1
		(set -o pipefail; fuzzbuild 0 docker-fuzz-valgrind np) 2>&1 | tee "${LOGDIR}/fuzz-build.log" || exit $?
		# fuzzbuild does not propagate every intermediate failure.
		run_logged "${LOGDIR}/fuzz-build-check.log" cmake --build "${FUZZ_BUILD}" || exit $?
		[[ -s "${FUZZ_BUILD}/smc_corpus/default.bin" ]] || {
			echo "Missing fuzz seed: ${FUZZ_BUILD}/smc_corpus/default.bin" >&2
			exit 1
		}

		echo "Starting Valgrind fuzzing for ${FUZZ_DURATION_SECONDS:-1000}s; logs: ${FUZZ_LOGDIR}"
		# Skip checking the Valgrind launcher; coverage comes from RMM.
		# Exit 99 turns Memcheck findings in RMM into AFL++ crash inputs.
		# SIGTERM lets Valgrind print its summary on timeout or shutdown.
		AFL_KILL_SIGNAL=15 \
		AFL_SKIP_BIN_CHECK=1 AFL_NO_FORKSRV=1 AFL_CRASH_EXITCODE=99 \
			run_fuzz_logged "${LOGDIR}/afl.log" afl-fuzz -i "${FUZZ_BUILD}/smc_corpus" \
			-o "_Fuzz/aflout/docker-fuzz-valgrind" \
			-V "${FUZZ_DURATION_SECONDS:-1000}" \
			-m "${FUZZ_MEMORY_LIMIT:-none}" -t "${FUZZ_VALGRIND_TIMEOUT_MS:-10000}" -- \
			valgrind --tool=memcheck --track-origins=yes \
			--leak-check=full --show-leak-kinds=all \
			--errors-for-leak-kinds=definite,indirect,possible \
			--error-limit=no --num-callers=30 -s \
			--error-exitcode=99 --log-file="${FUZZ_LOGDIR}/valgrind-%p.log" \
			"${FUZZ_BUILD}/Debug/rmm.elf" @@ || FUZZ_STATUS=$?
	else
		(fuzzbuild 0 docker-fuzz np) 2>&1 | tee "${LOGDIR}/fuzz-build.log" || exit $?
		echo "Start fuzzing"
		FUZZ_BUILD="${RMM_BUILD_DIR}/Fuzz/builds/docker-fuzz"
		AFL_AUTORESUME=${AFL_AUTORESUME:-1} run_fuzz_logged "${LOGDIR}/afl.log" \
			afl-fuzz -i "${FUZZ_BUILD}/smc_corpus" \
			-o "${RMM_BUILD_DIR}/Fuzz/aflout/docker-fuzz" -S s-docker-fuzz \
			-t "${FUZZ_TIMEOUT_MS:-1000}" -a "${FUZZ_INPUT_FORMAT:-binary}" -P "${FUZZ_STRATEGY:-exploit}" -p "${FUZZ_SCHEDULE:-mmopt}" \
			-V "${FUZZ_DURATION_SECONDS:-1000}" \
			-- "${FUZZ_BUILD}/Debug/rmm.elf" @@ || exit $?
	fi
	[[ $FUZZ_STATUS -eq 0 ]] || exit "$FUZZ_STATUS"
	echo "Fuzzing complete"
fi
