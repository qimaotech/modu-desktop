import Foundation
import Testing
@testable import ModuCore

struct RunTestsScriptTests {
    @Test func progressCountsMethodsAndReportsFailuresOnce() async throws {
        try await python("""
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            progress = runner.TestProgress(enabled=True, started=0)
            for line in [
                'Test run started.', 'Suite ExampleTests started.',
                'Test ranges(_:) started.',
                'Test case passing 1 argument value → 1 to ranges(_:) started.',
                'Test case passing 1 argument value → 2 to ranges(_:) started.',
                'Test ranges(_:) with 2 test cases passed after 0.1 seconds.',
                'Test failure() started.',
                'Test failure() recorded an issue at Example.swift:1:9: Expectation failed',
                'Test failure() recorded an issue at Example.swift:1:9: Expectation failed',
                'Test failure() failed after 0.1 seconds with 1 issue.',
                'Test run with 2 tests in 1 suite failed after 0.2 seconds.',
                'Test run() started.', 'Test run() passed after 0.01 seconds.',
            ]:
                progress.observe(line)
            assert len(progress.completed) == 3 and len(progress.failed) == 1
            assert not progress.running
            with tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / 'test.log'
                log.write_text('\\n'.join(progress.reported))
                runner.print_failure_summary(log, progress.reported)
            progress.observe("Test Case '-[LegacyTests testExample]' started.")
            progress.observe("Test Case '-[LegacyTests testExample]' passed (0.01 seconds).")
            assert len(progress.completed) == 4 and not progress.running
        assert output.getvalue().count('recorded an issue') == 1
        assert 'Failure diagnostics:' not in output.getvalue()
        """)
    }

    @Test func heartbeatUpdatesWithoutLogEventsAndStopsCleanly() async throws {
        try await python("""
        for terminal, no_color, term in [(False, False, 'xterm'), (True, False, 'xterm'),
                                         (True, True, 'xterm'), (True, False, 'dumb')]:
            updated = threading.Event()
            cleaning = threading.Event()
            runner.shutil.get_terminal_size = lambda: os.terminal_size((160, 24))
            class Capture(io.StringIO):
                def isatty(self):
                    return terminal
                def write(self, text):
                    result = super().write(text)
                    plain = re.sub(r'\\033\\[[0-9;]*[mK]', '', text)
                    if 'current ExampleTests/slow()' in plain:
                        updated.set()
                    if '] Cleanup' in plain:
                        cleaning.set()
                    return result
            output = Capture()
            with contextlib.redirect_stdout(output), mock.patch.dict(os.environ):
                os.environ['TERM'] = term
                os.environ.pop('NO_COLOR', None)
                if no_color:
                    os.environ['NO_COLOR'] = ''
                progress = runner.TestProgress(enabled=True, started=time.monotonic(), interval=0.01)
                progress.observe('Suite ExampleTests started.')
                progress.observe('Test slow() started.')
                progress.start()
                try:
                    assert updated.wait(2), 'No heartbeat while the log was silent'
                    progress.phase('Cleanup')
                    assert cleaning.wait(2), 'No heartbeat during cleanup'
                finally:
                    progress.close()
                heartbeat = output.getvalue()
                log = io.StringIO()
                runner.write_output(log, 'failure details', True, 'failure')
                assert log.getvalue() == 'failure details'
            assert not progress.thread.is_alive()
            plain = re.sub(r'\\033\\[[0-9;]*[mK]', '', heartbeat)
            assert 'Testing | completed 0 | failed 0' in plain
            assert ('\\033[2K' in heartbeat) == (terminal and term != 'dumb')
            assert bool(re.search(r'\\033\\[[0-9;]+m', heartbeat)) == (terminal and not no_color and term != 'dumb')
        """)
    }

    private func python(_ body: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        import contextlib, io, os, re, sys, tempfile, threading, time
        from pathlib import Path
        from unittest import mock
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(Path(sys.argv[1]) / 'script'))
        import run_tests as runner
        \(body)
        """
        let result = try await CommandRunner().run("/usr/bin/python3", ["-c", script, root.path], timeout: 10)
        #expect(result.status == 0, "\(result.text)\n\(String(decoding: result.stderr, as: UTF8.self))")
    }
}
