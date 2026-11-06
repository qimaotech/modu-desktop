#!/usr/bin/env python3
import argparse
from collections import deque
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
from prepare_mock_workspace import Cancelled, Jobs, interrupt

ROOT = Path(__file__).resolve().parent.parent
STYLES = {"muted": "2", "active": "1;34", "success": "32", "warning": "33", "failure": "1;31"}
FAILURE_PATTERN = re.compile(r": (?:fatal )?error:|^error:|^ld:|^Undefined symbols|recorded an issue|"
                             r"Test .+ failed(?: after| with)|^Test (?:run|cleanup) failed:|^Test run interrupted")


def main():
    parser = argparse.ArgumentParser(description="Run Xcode tests in an isolated, automatically cleaned environment.")
    parser.add_argument("--filter", default="MonoDeckTests")
    parser.add_argument("--verbose", action="store_true", help="Stream the full test log to the terminal.")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    extra = arguments.arguments
    if extra[:1] == ["--"]:
        extra = extra[1:]
    verbose = arguments.verbose or "--verbose" in extra
    extra = [value for value in extra if value != "--verbose"]
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupt)
    return run_tests(arguments.filter, extra, verbose)


def run_tests(test_filter, extra, verbose=False):
    started = time.monotonic()
    derived = Path(os.environ.get("MONO_DECK_DERIVED_DATA_PATH", str(Path(tempfile.gettempdir()) / "mono-deck-derived-data")))
    # Keep the log outside the disposable test environment, including on failure.
    log = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix="mono-deck-tests-", suffix=".log", delete=False)
    directory = Path(tempfile.mkdtemp(prefix="mono-deck-test-run-"))
    suite = f"MonoDeckTests.{uuid.uuid4()}"
    jobs = Jobs()
    progress = TestProgress(enabled=not verbose and "-enumerate-tests" not in extra, started=started)
    status = 1
    progress.message(f"Test log: {log.name}", "muted")
    log.write(f"Test environment: {directory}\nTest preferences: {suite}\n")
    try:
        environment = test_environment(directory, suite)
        results, explicit_results = result_path(extra, directory)
        command = ["xcodebuild", "-project", str(ROOT / "MonoDeck.xcodeproj"), "-scheme", "MonoDeck",
                   "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
                   "-derivedDataPath", str(derived), "-onlyUsePackageVersionsFromResolvedFile",
                   f"-only-testing:{test_filter}", "-parallel-testing-enabled", "NO",
                   "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "ENABLE_CODE_COVERAGE=NO", "test"]
        if not explicit_results:
            command += ["-resultBundlePath", str(results)]
        progress.start()
        progress.message("Running Xcode tests..." if "-enumerate-tests" not in extra else "Enumerating tests...", "active")
        xcode_started = time.monotonic()
        process = jobs.start(command + extra, cwd=ROOT, env=environment,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        testing = False
        with process.stdout:
            for line in process.stdout:
                write_output(log, line, verbose or "-enumerate-tests" in extra)
                progress.observe(line)
                if not testing and ("Test Suite 'Selected tests' started" in line or "Test run started" in line):
                    testing = True
                    progress.phase("Testing")
                    progress.message("Executing selected tests...", "active")
        status = process.wait()
        progress.phase("Reading results")
        progress.message(f"Xcode finished in {time.monotonic() - xcode_started:.1f}s.", "muted")
        if status < 0:
            status = 128 - status
        if status == 0 and "-enumerate-tests" not in extra:
            report = jobs.start(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(results), "--compact"],
                                cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            output, error = report.communicate()
            log.write(output + error)
            if report.returncode != 0:
                raise RuntimeError(f"Could not read the test results: {error.strip()}")
            summary = json.loads(output)
            total = summary.get("totalTestCount")
            skipped = summary.get("skippedTests", 0)
            if type(total) is not int or type(skipped) is not int or total - skipped <= 0:
                raise RuntimeError("No tests executed. Check TEST_FILTER; Swift Testing method identifiers include parentheses, such as method(_:).")
            executed = styled(str(total - skipped), "success")
            skipped_text = styled(str(skipped), "warning" if skipped else "muted")
            progress.message(f"Tests executed: {executed}; skipped: {skipped_text}.")
        if explicit_results:
            progress.message(f"Test results: {results}", "muted")
    except Cancelled as error:
        status = 128 + error.number
        write_output(log, "Test run interrupted.\n", verbose, "warning")
    except (OSError, ValueError, RuntimeError) as error:
        status = 1
        write_output(log, f"Test run failed: {error}\n", verbose, "failure")
    finally:
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, signal.SIG_IGN)
        cleaned = False
        cleanup_started = time.monotonic()
        progress.phase("Cleanup")
        try:
            jobs.stop()
            if cleanup(directory, suite, derived, log, verbose):
                shutil.rmtree(directory)
                cleaned = True
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            write_output(log, f"Test cleanup failed: {error}\n", verbose, "failure")
        progress.close()
        if cleaned:
            progress.message(f"Test environment removed: {directory}", "muted")
        else:
            message = f"Could not finish test cleanup; keeping environment: {directory}"
            write_output(log, message + "\n", False)
            progress.message(message, "failure")
            if status == 0:
                status = 1
        progress.message(f"Cleanup: {time.monotonic() - cleanup_started:.1f}s; total: {time.monotonic() - started:.1f}s; exit: {status}.",
                         "success" if status == 0 else "failure")
        log.close()
        if status != 0 and not verbose:
            print_failure_summary(Path(log.name), progress.reported)
    return status


def write_output(log, text, verbose, style=None):
    log.write(text)
    log.flush()
    if verbose:
        print(styled(text, style), end="", flush=True)


def styled(text, style):
    if style is None or not sys.stdout.isatty() or "NO_COLOR" in os.environ or os.environ.get("TERM") == "dumb":
        return text
    return f"\033[{STYLES[style]}m{text}\033[0m"


def console_message(text, style=None):
    print(styled(text, style), flush=True)


class TestProgress:
    def __init__(self, enabled, started, interval=None):
        self.enabled = enabled
        self.started = started
        self.stage = "Building"
        self.suite = ""
        self.running = {}
        self.completed = set()
        self.failed = set()
        self.reported = set()
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.thread = None
        self.inline_lines = 0
        self.cursor_hidden = False
        self.spinner_frame = 0
        self.terminal = sys.stdout.isatty() and os.environ.get("TERM") != "dumb"
        self.interval = interval if interval is not None else (0.1 if self.terminal else 10)

    def start(self):
        if self.enabled:
            if self.terminal:
                self.cursor_hidden = True
                print("\033[?25l", end="", flush=True)
            self.thread = threading.Thread(target=self.heartbeat, daemon=True)
            self.thread.start()

    def phase(self, stage):
        with self.lock:
            self.clear_line()
            self.stage = stage

    def message(self, text, style=None):
        with self.lock:
            self.clear_line()
            console_message(text, style)

    def observe(self, line):
        if not self.enabled:
            return
        text = line.strip()
        with self.lock:
            suite = re.search(r"\bSuite (.+) started\.$", text)
            if suite:
                self.suite = suite[1]
                self.stage = "Testing"
            test = re.search(r"\bTest (?!case passing |run (?:started|with)\b)(.+) started\.$", text)
            result = re.search(r"\bTest (?!case passing |run (?:started|with)\b)(.+?) (passed|failed|skipped)(?: after|:|\.)", text)
            legacy = re.search(r"Test Case '(.+)' (started|passed|failed|skipped)", text)
            if legacy:
                name, outcome = legacy.groups()
            elif test:
                name, outcome = test[1], "started"
            elif result:
                name, outcome = result.groups()
                name = re.sub(r" with \d+ test cases?$", "", name)
            else:
                name = outcome = None
            if name:
                key = (self.suite, name)
                if outcome == "started":
                    self.stage = "Testing"
                    self.running[key] = time.monotonic()
                else:
                    self.running.pop(key, None)
                    self.completed.add(key)
                    if outcome == "failed":
                        self.failed.add(key)
            if FAILURE_PATTERN.search(text) and text not in self.reported and len(self.reported) < 20:
                self.reported.add(text)
                self.clear_line()
                console_message(f"Failure: {text[:800]}", "failure")

    def heartbeat(self):
        next_render = 0
        while not self.stopped.wait(self.interval):
            with self.lock:
                now = time.monotonic()
                if not self.terminal or not self.inline_lines or now >= next_render:
                    self.render(now)
                    next_render = now + 1
                else:
                    self.animate()

    def render(self, now):
        elapsed = int(now - self.started)
        parts = []
        if self.terminal:
            parts.append((self.spinner() + " ", "active"))
        parts += [(f"[{elapsed // 60:02d}:{elapsed % 60:02d}] ", "muted"), (self.stage, "active")]
        rows = [parts]
        width = max(1, shutil.get_terminal_size().columns - 1) if self.terminal else None
        if self.stage == "Testing":
            parts += [(" | completed ", "muted"), (str(len(self.completed)), "success" if self.completed else "muted"),
                      (" | failed ", "muted"), (str(len(self.failed)), "failure" if self.failed else "muted")]
            if self.running:
                (suite, name), began = min(self.running.items(), key=lambda item: item[1])
                current = f"{suite}/{name}" if suite else name
                duration = f" ({int(now - began)}s)"
                if width is not None:
                    available = max(0, width - 4 - len(duration))
                    if len(current) > available:
                        current = current[:max(0, available - 1)] + ("…" if available else "")
                rows.append([("  ↳ ", "muted"), (current, None), (duration, "muted")])
                if len(self.running) > 1:
                    parts.append((f" | {len(self.running)} running", "muted"))
            elif self.suite:
                rows.append([("  ↳ ", "muted"), (self.suite, None)])
        rendered = []
        for row in rows:
            remaining = width
            line = []
            for text, style in row:
                if remaining is not None:
                    text = text[:remaining]
                    remaining -= len(text)
                if text:
                    line.append(styled(text, style))
            rendered.append("".join(line))
        self.clear_line()
        if self.terminal:
            print("\n".join(rendered), end="", flush=True)
            self.inline_lines = len(rendered)
        else:
            print("\n".join(rendered), flush=True)

    def animate(self):
        up = f"\033[{self.inline_lines - 1}A" if self.inline_lines > 1 else ""
        down = f"\033[{self.inline_lines - 1}B" if self.inline_lines > 1 else ""
        print("\r" + up + styled(self.spinner(), "active") + "\r" + down, end="", flush=True)

    def spinner(self):
        frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        frame = frames[self.spinner_frame % len(frames)]
        self.spinner_frame += 1
        return frame

    def clear_line(self):
        if self.inline_lines:
            print("\r\033[2K" + "\033[1A\r\033[2K" * (self.inline_lines - 1), end="", flush=True)
            self.inline_lines = 0

    def close(self):
        self.stopped.set()
        if self.thread:
            self.thread.join()
        with self.lock:
            self.clear_line()
            if self.cursor_hidden:
                print("\033[?25h", end="", flush=True)
                self.cursor_hidden = False


def print_failure_summary(path, reported=()):
    diagnostics = []
    tail = deque(maxlen=10)
    found = False
    with path.open(errors="replace") as log:
        for line in log:
            text = line.strip()
            if text:
                tail.append(text)
            matches = FAILURE_PATTERN.search(text)
            if matches:
                found = True
            if matches and text not in reported and text not in diagnostics and len(diagnostics) + len(reported) < 20:
                diagnostics.append(text)
                if len(diagnostics) == 20:
                    break
    if diagnostics or not found:
        console_message("Failure diagnostics:", "failure")
        for text in diagnostics if found else tail:
            console_message(text[:800], "failure")
    console_message(f"Full diagnostics: {path}", "muted")


def test_environment(directory, suite):
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith(("MONO_DECK_TEST_", "TEST_RUNNER_MONO_DECK_TEST_")) or key in ("MONO_DECK_UNIT_TEST_HOST", "TEST_RUNNER_MONO_DECK_UNIT_TEST_HOST"):
            del environment[key]
    for name in ("home", "support", "tmp", "hosts"):
        (directory / name).mkdir()
    shell = directory / "login-shell"
    shell.write_text("#!/bin/sh\nexit 1\n")
    shell.chmod(0o755)
    values = {"MONO_DECK_TEST_DEFAULTS": suite, "MONO_DECK_TEST_SUPPORT_DIRECTORY": str(directory / "support"),
              "MONO_DECK_TEST_HOME_DIRECTORY": str(directory / "home"), "MONO_DECK_TEST_LOGIN_SHELL": str(shell),
              "MONO_DECK_TEST_SESSION_DIRECTORY": str(directory), "TMPDIR": str(directory / "tmp") + "/",
              "MONO_DECK_UNIT_TEST_HOST": "1"}
    for key, value in values.items():
        environment[key] = value
        environment[f"TEST_RUNNER_{key}"] = value
    return environment


def result_path(arguments, directory):
    positions = [index for index, value in enumerate(arguments) if value == "-resultBundlePath"]
    if not positions:
        return directory / "Results.xcresult", False
    if len(positions) != 1 or positions[0] + 1 >= len(arguments):
        raise ValueError("Specify -resultBundlePath once, followed by its destination.")
    path = Path(arguments[positions[0] + 1])
    return (path if path.is_absolute() else ROOT / path), True


def cleanup(directory, suite, derived, log, verbose):
    success = True
    for identity in sorted((directory / "hosts").glob("*.json")):
        process = subprocess.run(["xcrun", "swift", "-module-cache-path", str(derived / "VerificationModuleCache"),
                                  str(ROOT / "script/quit_app.swift"), "--identity", str(identity)], cwd=ROOT,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        write_output(log, process.stdout, verbose)
        success = process.returncode == 0 and success
    if not success:
        return False
    removed = subprocess.run(["/usr/bin/defaults", "delete", suite], capture_output=True)
    if removed.returncode != 0:
        remaining = subprocess.run(["/usr/bin/defaults", "read", suite], capture_output=True)
        return remaining.returncode != 0
    return True


if __name__ == "__main__":
    sys.exit(main())
