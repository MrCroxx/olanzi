"""后台管理验证：身份核验、端口保护、就绪握手与私有文件。"""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from olanzi_daemon import DaemonManager, notify_ready


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manager = DaemonManager(self.root / "state", self.root / "logs", self.root / "olanzi.py")
        self.metadata = {"pid": 12345, "port": 8765, "token": "a" * 64, "script": self.manager.script}
        self.output = io.StringIO()
        self.stdout = contextlib.redirect_stdout(self.output)
        self.stdout.__enter__()

    def tearDown(self):
        self.stdout.__exit__(None, None, None)
        self.temp.cleanup()

    def save(self):
        self.manager.state_dir.mkdir(exist_ok=True)
        self.manager._save(self.metadata)

    def test_status_does_not_create_files(self):
        self.assertEqual(self.manager.status(), 1)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_process_identity_requires_repository_path_and_full_nonce(self):
        command = f"/usr/bin/python3 -u {self.manager.script} --daemon-token {self.metadata['token']}"
        for text, expected in ((command, True), (command + "b", False),
                               (command.replace(self.manager.script, "/other/olanzi.py"), False),
                               (command.replace("--daemon-token", "--other-token"), False)):
            with self.subTest(command=text), patch("olanzi_daemon.subprocess.run", return_value=Mock(
                    returncode=0, stdout=text)):
                self.assertEqual(self.manager._matches(self.metadata), expected)

    def test_stale_pid_is_never_signaled(self):
        self.save()
        with patch.object(self.manager, "_matches", return_value=False), patch("olanzi_daemon.os.kill") as kill:
            self.assertEqual(self.manager.stop(), 0)
            kill.assert_not_called()
        self.assertFalse(self.manager.metadata_path.exists())

    def test_corrupt_metadata_is_rejected_without_signal(self):
        self.save()
        self.manager.metadata_path.write_text('{"pid": 12345}')
        with patch("olanzi_daemon.os.kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "无效"):
                self.manager.stop()
            kill.assert_not_called()

    def test_busy_port_preserves_foreground_process(self):
        with patch.object(self.manager, "_port_available", return_value=False), \
                patch("olanzi_daemon.subprocess.Popen") as popen, patch("olanzi_daemon.os.kill") as kill:
            self.assertEqual(self.manager.start(), 1)
            popen.assert_not_called()
            kill.assert_not_called()
        self.assertIn("端口 8765 已被占用", self.output.getvalue())

    def test_start_is_idempotent(self):
        self.save()
        with patch.object(self.manager, "_matches", return_value=True), \
                patch("olanzi_daemon.subprocess.Popen") as popen:
            self.assertEqual(self.manager.start(), 0)
            popen.assert_not_called()

    def test_start_detaches_and_creates_private_files_without_exposing_nonce(self):
        child = Mock(pid=12345)
        with patch.object(self.manager, "_port_available", return_value=True), \
                patch.object(self.manager, "_wait_ready", return_value=True), \
                patch("olanzi_daemon.subprocess.Popen", return_value=child) as popen:
            self.assertEqual(self.manager.start(9876, demo=True), 0)
        metadata = json.loads(self.manager.metadata_path.read_text())
        command = popen.call_args.args[0]
        options = popen.call_args.kwargs
        self.assertIn("--no-browser", command)
        self.assertIn("--demo", command)
        self.assertIn(metadata["token"], command)
        self.assertEqual(metadata["port"], 9876)
        self.assertTrue(options["start_new_session"])
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertEqual(len(options["pass_fds"]), 1)
        self.assertNotIn(metadata["token"], self.output.getvalue())
        for path in (self.manager.metadata_path, self.manager.log_path, self.manager.state_dir / "daemon.lock"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        for fd in options["pass_fds"]:
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_failed_start_only_interrupts_created_child(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        with patch.object(self.manager, "_port_available", return_value=True), \
                patch.object(self.manager, "_wait_ready", return_value=False), \
                patch("olanzi_daemon.subprocess.Popen", return_value=child), patch("olanzi_daemon.os.kill") as kill:
            self.assertEqual(self.manager.start(), 1)
            child.send_signal.assert_called_once_with(signal.SIGINT)
            kill.assert_not_called()
        self.assertFalse(self.manager.metadata_path.exists())

    def test_unfinished_shutdown_retains_metadata_and_does_not_sigkill(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        child.wait.side_effect = subprocess.TimeoutExpired("python", 3)
        with patch.object(self.manager, "_port_available", return_value=True), \
                patch.object(self.manager, "_wait_ready", return_value=False), \
                patch("olanzi_daemon.subprocess.Popen", return_value=child):
            self.assertEqual(self.manager.start(), 1)
        child.send_signal.assert_called_once_with(signal.SIGINT)
        self.assertTrue(self.manager.metadata_path.exists())

    def test_metadata_write_failure_cleans_up_new_child(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        with patch.object(self.manager, "_port_available", return_value=True), \
                patch.object(self.manager, "_save", side_effect=OSError("磁盘不可写")), \
                patch("olanzi_daemon.subprocess.Popen", return_value=child):
            with self.assertRaises(OSError):
                self.manager.start()
        child.send_signal.assert_called_once_with(signal.SIGINT)
        child.wait.assert_called_once_with(timeout=3)

    def test_stop_interrupts_only_verified_pid_and_waits_for_exit(self):
        self.save()
        with patch.object(self.manager, "_matches", side_effect=[True, False]), \
                patch("olanzi_daemon.os.kill") as kill:
            self.assertEqual(self.manager.stop(), 0)
            kill.assert_called_once_with(12345, signal.SIGINT)
        self.assertFalse(self.manager.metadata_path.exists())

    def test_pipe_readiness_is_specific_to_child_not_http_port(self):
        read_fd, write_fd = os.pipe()
        try:
            notify_ready(write_fd)
            child = Mock()
            child.poll.return_value = None
            self.assertTrue(self.manager._wait_ready(child, read_fd, timeout=0.2))
            with self.assertRaises(OSError):
                os.fstat(write_fd)
        finally:
            os.close(read_fd)

    def test_pipe_eof_reports_start_failure(self):
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        try:
            child = Mock()
            child.poll.return_value = 1
            self.assertFalse(self.manager._wait_ready(child, read_fd, timeout=0.2))
        finally:
            os.close(read_fd)


if __name__ == "__main__":
    unittest.main()
