#!/usr/bin/env python3
"""Exercise actual terminal input, including the download-to-bash launch path."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import termios
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "switch-mac.sh"
DOWN = b"\x1b[B"
UP = b"\x1b[A"
ENTER = b"\r"
MENU = b"Esc/q cancel"


class Terminal:
    def __init__(self, directory, piped=False, term="xterm-256color"):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ, HOME=str(directory), TERM=term,
                       PATH=str(directory / "bin") + ":" + os.environ["PATH"])
            argv = ["/bin/bash", str(SCRIPT)]
            if piped:
                # Like curl | bash: source comes through stdin, keys through tty.
                argv = ["/bin/bash", "-c", 'cat "$1" | /bin/bash', "test", str(SCRIPT)]
            os.execve(argv[0], argv, env)
        import fcntl
        import struct
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.initial = termios.tcgetattr(self.fd)
        self.output = b""
        self.offset = 0
        self.reaped = False

    def read(self):
        if select.select([self.fd], [], [], 0.05)[0]:
            try:
                self.output += os.read(self.fd, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise

    def expect(self, text):
        deadline = time.monotonic() + 10
        while text not in self.output[self.offset:]:
            if time.monotonic() > deadline:
                raise AssertionError(f"Missing {text!r}: {self.output!r}")
            self.read()
        self.offset = self.output.index(text, self.offset) + len(text)

    def send(self, keys):
        os.write(self.fd, keys)

    def choose(self, keys):
        self.expect(MENU)
        self.send(keys)

    def finish(self, expected=0):
        deadline = time.monotonic() + 10
        while True:
            self.read()
            pid, result = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.reaped = True
                self.read()
                code = os.waitstatus_to_exitcode(result)
                assert code == expected, (code, self.output)
                assert termios.tcgetattr(self.fd) == self.initial, "Terminal mode leaked"
                return
            if time.monotonic() > deadline:
                raise AssertionError(f"Script did not exit: {self.output!r}")

    def close(self):
        if not self.reaped:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


class Menus(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="switch-mac-tty-")
        self.addCleanup(self.sandbox.cleanup)
        self.directory = Path(self.sandbox.name)
        (self.directory / "bin").mkdir()
        for name in ("claude", "codex"):
            mock = self.directory / "bin" / name
            mock.write_text("#!/bin/sh\nexit 0\n")
            mock.chmod(0o700)

    def terminal(self, **kwargs):
        terminal = Terminal(self.directory, **kwargs)
        self.addCleanup(terminal.close)
        return terminal

    def fixture(self, name, content):
        path = self.directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_codex_only_arrows_and_hidden_new_token(self):
        terminal = self.terminal()
        terminal.choose(DOWN + ENTER)
        terminal.choose(ENTER)
        terminal.expect(b"Codex token: ")
        terminal.send(b"codex-hidden-fixture\r")
        terminal.finish()
        config = (self.directory / ".codex/config.toml").read_text()
        self.assertIn('model_provider = "newapi"', config)
        self.assertIn('codex-hidden-fixture', config)
        self.assertNotIn(b"codex-hidden-fixture", terminal.output)
        self.assertFalse((self.directory / ".claude").exists())

    def test_pipe_both_saved_and_replace_token_then_roundtrip(self):
        settings = self.fixture(".claude/settings.json", '{"env":{"KEEP":"yes"}}')
        config = self.fixture(".codex/config.toml", '[mcp_servers.keep]\ncommand = "keep"\n')
        self.fixture(".claude/claude-provider.conf", "NEWAPI_TOKEN=claude-saved-fixture\n")
        self.fixture(".codex/newapi-provider.conf", "NEWAPI_TOKEN=codex-saved-fixture\n")
        terminal = self.terminal(piped=True)
        terminal.choose(DOWN + DOWN + ENTER)
        terminal.choose(ENTER)
        terminal.choose(ENTER)  # reuse Claude's token
        terminal.choose(DOWN + ENTER)  # replace Codex's token
        terminal.expect(b"Codex token: ")
        terminal.send(b"codex-replacement-fixture\r")
        terminal.finish()
        self.assertEqual(json.loads(settings.read_text())["env"]["KEEP"], "yes")
        self.assertIn("codex-replacement-fixture", config.read_text())
        self.assertNotIn(b"codex-replacement-fixture", terminal.output)
        self.assertNotIn(b"claude-saved-fixture", terminal.output)
        terminal = self.terminal(piped=True)
        terminal.choose(DOWN + DOWN + ENTER)
        terminal.choose(ENTER)  # default now highlights official providers
        terminal.finish()
        self.assertEqual(json.loads(settings.read_text()), {"env": {"KEEP": "yes"}})
        self.assertEqual(config.read_text(), '[mcp_servers.keep]\ncommand = "keep"\n')

    def test_escape_cancels_without_importing_legacy_tokens(self):
        settings = self.fixture(".claude/settings.json", json.dumps({"env": {
            "ANTHROPIC_BASE_URL": "https://ai.mobilesentrix.com",
            "ANTHROPIC_AUTH_TOKEN": "legacy-fixture"}}))
        original = settings.read_bytes()
        terminal = self.terminal()
        terminal.choose(b"\x1b")
        terminal.finish()
        self.assertEqual(settings.read_bytes(), original)
        self.assertFalse((self.directory / ".claude/claude-provider.conf").exists())

    def test_up_wraps_to_exit_in_application_cursor_mode(self):
        terminal = self.terminal()
        terminal.choose(b"\x1bOA" + ENTER)  # SS3 variant of Up
        terminal.finish()
        self.assertFalse((self.directory / ".claude").exists())
        self.assertFalse((self.directory / ".codex").exists())

    def test_q_at_provider_menu(self):
        terminal = self.terminal()
        terminal.choose(ENTER)
        terminal.choose(b"q")
        terminal.finish()
        self.assertFalse((self.directory / ".claude").exists())

    def test_cancel_token_menu(self):
        self.fixture(".claude/claude-provider.conf", "NEWAPI_TOKEN=saved-fixture\n")
        terminal = self.terminal()
        terminal.choose(ENTER)
        terminal.choose(ENTER)
        terminal.choose(UP + ENTER)  # wraps to Cancel
        terminal.finish()
        self.assertFalse((self.directory / ".claude/settings.json").exists())

    def test_ctrl_c_restores_menu_terminal(self):
        terminal = self.terminal()
        terminal.choose(b"\x03")
        terminal.finish(expected=130)
        self.assertIn(b"\x1b[?25h", terminal.output)

    def test_ctrl_c_restores_hidden_input(self):
        terminal = self.terminal()
        terminal.choose(ENTER)
        terminal.choose(ENTER)
        terminal.expect(b"Claude token: ")
        terminal.send(b"\x03")
        terminal.finish(expected=130)
        self.assertFalse((self.directory / ".claude").exists())

    def test_dumb_terminal_numbered_fallback(self):
        terminal = self.terminal(term="dumb")
        terminal.expect(b"q = cancel): ")
        terminal.send(b"4\r")
        terminal.finish()
        self.assertNotIn(b"\x1b[?25l", terminal.output)

    def test_plain_mode_uses_stdin_and_eof_cancels(self):
        env = dict(os.environ, HOME=str(self.directory))
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--plain"],
                                input=b"", capture_output=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Input closed", result.stderr)
        self.assertFalse((self.directory / ".claude").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
