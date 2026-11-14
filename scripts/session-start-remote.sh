#!/usr/bin/env bash
# Prepare web checkouts on startup and resume, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the checkout; run task setup:remote."
    exit 0
fi

# Do this synchronously, before detaching setup and before even looking up task:
# a child preparation process cannot change the agent's environment. Claude
# evaluates these exports before subsequent Bash commands, after shell startup.
# Only a bootstrap-owned environment supplies a managed toolchain. Decide
# persistence before emitting remedies: a saved export already fixes shadows.
if [ -f "${HARMON_PREFIX:-/usr/local}/share/harmon-remote-env/manifest.json" ]; then
    if session_env="$(bash "$ROOT/scripts/reconcile-toolchain.sh" --session-env 2>/dev/null)"; then
        if [ -n "$session_env" ]; then
            path_warning=""
            if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
                if printf '\n%s\n' "$session_env" >>"$CLAUDE_ENV_FILE"; then
                    echo "==> Managed PATH saved for agent commands: ${HARMON_BIN:-${HARMON_PREFIX:-/usr/local}/bin} first."
                else
                    path_warning="could not persist managed PATH in CLAUDE_ENV_FILE; managed PATH applies only to preparation."
                fi
            else
                path_warning="CLAUDE_ENV_FILE is unavailable; managed PATH applies only to preparation."
            fi
            if [ -n "$path_warning" ]; then
                # PATH is still the incoming one. Send only the helper's
                # diagnostics to stdout; discard its duplicate export.
                bash "$ROOT/scripts/reconcile-toolchain.sh" --session-env 2>&1 >/dev/null
                echo "==> WARNING: SessionStart remote preparation: ${path_warning} Put ${HARMON_BIN:-${HARMON_PREFIX:-/usr/local}/bin} first on PATH in agent shells."
            fi
            eval "$session_env"
        fi
    else
        echo "==> WARNING: SessionStart remote preparation: could not prepare managed PATH; run bash scripts/reconcile-toolchain.sh --status."
    fi
fi

# Only the disposable waiter uses timeout; preparation never receives its signals.
if ! command -v timeout >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because timeout is unavailable; run task setup:remote."
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because python3 is unavailable; run task setup:remote."
    exit 0
fi
if ! state_dir="$(git -C "$ROOT" rev-parse --absolute-git-dir)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the git directory; run task setup:remote."
    exit 0
fi

# Python's standard library supplies portable session detachment and advisory
# locks (including on macOS). A short launch lock serializes metadata publication;
# the worker holds a separate run lock until task exits. Neither lock is passed
# to task or its descendants, so an escaped child cannot retain it indefinitely.
#
# Invariants (one program, two roles, so both read the same state the same way):
#   * Never signal preparation. Observers only read.
#   * The run lock says the supervisor lives; it does not say setup lives. The
#     supervisor can die alone while task keeps running. So task records
#     itself (PID plus start time, which survives a reused PID) in its run
#     directory's task.json *before* it execs, still holding the run lock it
#     inherited from the supervisor: the lock is held without a gap until the
#     record exists. A launcher that finds the lock free but a recorded task
#     alive observes that run instead of starting a peer.
#   * A run directory is deleted only after it was superseded (a later launch
#     proved its worker gone and stopped publishing it as active, atomically
#     under the launch lock) and stayed superseded for a day. Hooks attach to a
#     directory only while it is the active run and are bounded by their own
#     90 s wait, so no hook reads a directory a day after it was superseded.
#     The active run is never superseded, hence never deleted.
supervisor() {
    python3 - "$@" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

SUPERSEDED_GRACE = 24 * 60 * 60


def read_json(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def process_start(pid):
    """The process's start time as ps prints it ("" when ps cannot say)."""
    try:
        listing = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)], capture_output=True,
                                 text=True, env=dict(os.environ, TZ="UTC", LC_ALL="C")).stdout
    except OSError:
        return ""
    return listing.strip()


def task_alive(directory):
    """True when the task recorded for this run is still the live process."""
    record = read_json(Path(directory) / "task.json")
    pid = record.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)  # existence probe; no signal is delivered
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    now = process_start(pid)
    if not now:
        return True
    stat, _, start = now.partition(" ")
    # A zombie has exited; a different start time is a reused PID.
    return not stat.startswith("Z") and start.strip() == record.get("start", start.strip())


def retire_runs(state):
    """Supersede every run directory, then delete those superseded for a day."""
    now = time.time()
    for run in state.glob("run-*"):
        if run.is_symlink() or not run.is_dir():
            continue
        marker = run / "superseded"
        if not marker.exists():
            marker.write_text("")
        elif now - marker.stat().st_mtime > SUPERSEDED_GRACE:
            shutil.rmtree(run, ignore_errors=True)


def launch(root, state):
    state.mkdir(mode=0o700, exist_ok=True)
    with (state / "launch.lock").open("a") as launch_lock:
        fcntl.flock(launch_lock, fcntl.LOCK_EX)
        with (state / "run.lock").open("a") as run_lock:
            try:
                fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                # An active setup owns the run lock. Observe it; never launch a peer.
                print(json.loads((state / "active.json").read_text())["directory"])
                return
            previous = read_json(state / "active.json").get("directory")
            if previous and not (Path(previous) / "status").exists() and task_alive(previous):
                # Only the supervisor died; its task still prepares this checkout.
                print(previous)
                return
            try:
                retire_runs(state)
            except Exception:
                pass  # housekeeping must never prevent a launch
            directory = Path(tempfile.mkdtemp(prefix="run-", dir=state))
            with (directory / "output.log").open("w") as log:
                pid = os.fork()
                if pid == 0:
                    # Close inherited hook pipes before starting any slow work.
                    os.setsid()
                    os.close(launch_lock.fileno())
                    with open(os.devnull) as null:
                        os.dup2(null.fileno(), 0)
                    os.dup2(log.fileno(), 1)
                    os.dup2(log.fileno(), 2)
                    supervise(root, directory)
                    os._exit(0)
            write_json(state / "active.json", {"directory": str(directory), "pid": pid})
            print(directory)


def supervise(root, directory):
    rc = 1
    try:
        task = os.fork()
        if task == 0:
            try:
                # Still holding the inherited run lock: record before exec,
                # which then drops that descriptor (close-on-exec).
                write_json(directory / "task.json", {"pid": os.getpid(), "start": process_start(os.getpid()).partition(" ")[2].strip()})
                os.closerange(3, 65536)
                os.execvp("task", ["task", "--dir", root, "setup:remote"])
            except BaseException as error:
                print(f"Could not run setup:remote: {error}", file=sys.stderr, flush=True)
                os._exit(1)
        code = os.waitpid(task, 0)[1]
        rc = os.WEXITSTATUS(code) if os.WIFEXITED(code) else -os.WTERMSIG(code)
    except Exception as error:
        print(f"Could not run setup:remote: {error}", file=sys.stderr, flush=True)
    finally:
        (directory / "status.tmp").write_text(str(rc) + "\n")
        (directory / "status.tmp").replace(directory / "status")


def check(state, directory):
    with (state / "launch.lock").open("a") as launch_lock:
        fcntl.flock(launch_lock, fcntl.LOCK_EX)
        with (state / "run.lock").open("a") as run_lock:
            try:
                fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                supervisor_alive = False
            except BlockingIOError:
                supervisor_alive = True
            active = json.loads((state / "active.json").read_text())
            if active["directory"] == directory and task_alive(directory):
                print("running")
                print(read_json(Path(directory) / "task.json")["pid"])
            elif active["directory"] == directory and supervisor_alive:
                print("running")
                print(active["pid"])
            else:
                print("ended")
                print(active.get("pid", 0))


role = sys.argv[1]
if role == "launch":
    launch(sys.argv[2], Path(sys.argv[3]))
else:
    check(Path(sys.argv[2]), sys.argv[3])
PY
}

if ! run_dir="$(supervisor launch "$ROOT" "$state_dir/session-start-remote")"; then
    echo "==> WARNING: SessionStart remote preparation: could not start or observe preparation; run task setup:remote after checking for an existing setup."
    exit 0
fi

output_file="$run_dir/output.log"
status_file="$run_dir/status"

# This process group contains only the waiter. The new-session worker has no
# hook stdin/stdout/stderr pipes and keeps running after the 90-second deadline.
timeout 90s bash -c 'while [ ! -f "$1" ]; do sleep 0.1; done' bash "$status_file" >/dev/null 2>&1 || true
worker_pid=""
if [ ! -f "$status_file" ]; then
    # Both new launches and observers re-check liveness after their wait. PIDs
    # can be reused, and a dead worker cannot write its completion status. The
    # reported PID is the live setup's own, which outlives a dead supervisor.
    if ! worker_state="$(supervisor check "$state_dir/session-start-remote" "$run_dir")"; then
        echo "==> WARNING: SessionStart remote preparation: could not check setup:remote status (log: $output_file); inspect preparation before re-running task setup:remote."
        exit 0
    fi
    worker_pid="${worker_state##*$'\n'}"
    worker_state="${worker_state%%$'\n'*}"
    # Completion can race the liveness check; status is published before the
    # worker releases the lock, so re-read it before declaring a lost worker.
    if [ ! -f "$status_file" ]; then
        if [ "$worker_state" = running ]; then
            echo "==> WARNING: SessionStart remote preparation: setup:remote still running (worker PID $worker_pid; log: $output_file). Lefthook hooks, related repos and dependencies may not be ready; wait for $status_file before working. Re-run task setup:remote only if that file is still missing and worker PID $worker_pid is no longer running (kill -0 $worker_pid fails); a manual run takes no lock."
        else
            echo "==> WARNING: SessionStart remote preparation: setup:remote ended without a status (log: $output_file); run task setup:remote again."
        fi
        exit 0
    fi
fi

cat "$output_file" >&2
if [ "$(cat "$status_file")" = 0 ]; then
    summary="setup:remote completed."
    while IFS= read -r line; do
        case "$line" in
        # The last status marker wins, including a final clean status that
        # supersedes a tool's earlier marker-shaped output.
        '==> setup:remote completed.'* | '==> setup:remote completed with warnings:'*) summary="${line#==> }" ;;
        esac
    done <"$output_file"
    echo "==> SessionStart remote preparation: ${summary}"
else
    # Re-probe without installing so failures still name drift and its remedy.
    drift="$(cd "$ROOT" && bash scripts/reconcile-toolchain.sh --status)" || drift="toolchain status unavailable"
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again.${drift:+ ${drift}}"
fi
# Preparation failures must never prevent a session from starting.
exit 0
