#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from prepare_mock_workspace import Cancelled, Jobs, interrupt

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description="Run Xcode tests in an isolated, automatically cleaned environment.")
    parser.add_argument("--filter", default="ModuDesktopTests")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    extra = arguments.arguments
    if extra[:1] == ["--"]:
        extra = extra[1:]
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupt)
    return run_tests(arguments.filter, extra)


def run_tests(test_filter, extra):
    derived = Path(os.environ.get("MODU_DERIVED_DATA_PATH", str(Path(tempfile.gettempdir()) / "modu-desktop-derived-data")))
    directory = Path(tempfile.mkdtemp(prefix="modu-test-run-"))
    suite = f"ModuTests.{uuid.uuid4()}"
    jobs = Jobs()
    status = 1
    print(f"Test environment: {directory}", flush=True)
    print(f"Test preferences: {suite}", flush=True)
    try:
        environment = test_environment(directory, suite)
        results, explicit_results = result_path(extra, directory)
        command = ["xcodebuild", "-project", str(ROOT / "ModuDesktop.xcodeproj"), "-scheme", "ModuDesktop",
                   "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
                   "-derivedDataPath", str(derived), "-onlyUsePackageVersionsFromResolvedFile",
                   f"-only-testing:{test_filter}", "-parallel-testing-enabled", "NO",
                   "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "ENABLE_CODE_COVERAGE=NO", "test"]
        if not explicit_results:
            command += ["-resultBundlePath", str(results)]
        process = jobs.start(command + extra, cwd=ROOT, env=environment)
        status = process.wait()
        if status < 0:
            status = 128 - status
        if status == 0 and "-enumerate-tests" not in extra:
            report = jobs.start(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(results), "--compact"],
                                cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            output, error = report.communicate()
            if report.returncode != 0:
                raise RuntimeError(f"Could not read the test results: {error.strip()}")
            summary = json.loads(output)
            total = summary.get("totalTestCount")
            skipped = summary.get("skippedTests", 0)
            if type(total) is not int or type(skipped) is not int or total - skipped <= 0:
                raise RuntimeError("No tests executed. Check TEST_FILTER; Swift Testing method identifiers include parentheses, such as method(_:).")
            print(f"Tests executed: {total - skipped}; skipped: {skipped}.", flush=True)
        if explicit_results:
            print(f"Test results: {results}", flush=True)
    except Cancelled as error:
        status = 128 + error.number
        print("Test run interrupted.", file=sys.stderr)
    except (OSError, ValueError, RuntimeError) as error:
        status = 1
        print(f"Test run failed: {error}", file=sys.stderr)
    finally:
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, signal.SIG_IGN)
        cleaned = False
        try:
            jobs.stop()
            if cleanup(directory, suite, derived):
                shutil.rmtree(directory)
                cleaned = True
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Test cleanup failed: {error}", file=sys.stderr)
        if cleaned:
            print(f"Test environment removed: {directory}", flush=True)
        else:
            print(f"Could not finish test cleanup; keeping environment: {directory}", file=sys.stderr)
            if status == 0:
                status = 1
    return status


def test_environment(directory, suite):
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith(("MODU_TEST_", "TEST_RUNNER_MODU_TEST_")) or key in ("MODU_UNIT_TEST_HOST", "TEST_RUNNER_MODU_UNIT_TEST_HOST"):
            del environment[key]
    for name in ("home", "support", "tmp", "hosts"):
        (directory / name).mkdir()
    shell = directory / "login-shell"
    shell.write_text("#!/bin/sh\nexit 1\n")
    shell.chmod(0o755)
    values = {"MODU_TEST_DEFAULTS": suite, "MODU_TEST_SUPPORT_DIRECTORY": str(directory / "support"),
              "MODU_TEST_HOME_DIRECTORY": str(directory / "home"), "MODU_TEST_LOGIN_SHELL": str(shell),
              "MODU_TEST_SESSION_DIRECTORY": str(directory), "TMPDIR": str(directory / "tmp") + "/",
              "MODU_UNIT_TEST_HOST": "1"}
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


def cleanup(directory, suite, derived):
    success = True
    for identity in sorted((directory / "hosts").glob("*.json")):
        process = subprocess.run(["xcrun", "swift", "-module-cache-path", str(derived / "VerificationModuleCache"),
                                  str(ROOT / "script/quit_app.swift"), "--identity", str(identity)], cwd=ROOT)
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
