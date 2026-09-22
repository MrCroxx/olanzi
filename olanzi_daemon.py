"""手动管理本地后台进程，不注册登录项或开机服务。"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time


def notify_ready(fd):
    """子进程绑定 HTTP 端口后通知父进程；不通过网页判断进程身份。"""
    if fd is not None:
        try:
            os.write(fd, b"READY\n")
        finally:
            os.close(fd)


class DaemonManager:
    def __init__(self, state_dir=None, log_dir=None, script=None):
        self.state_dir = Path(state_dir or Path.home() / "Library/Application Support/Olanzi")
        self.log_dir = Path(log_dir or Path.home() / "Library/Logs/Olanzi")
        self.metadata_path = self.state_dir / "daemon.json"
        self.log_path = self.log_dir / "daemon.log"
        self.script = str(Path(script or Path(__file__).with_name("olanzi.py")).resolve())

    @contextmanager
    def _lock(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.state_dir / "daemon.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def _read(self):
        try:
            metadata = json.loads(self.metadata_path.read_text())
        except FileNotFoundError:
            return None
        except (ValueError, UnicodeError) as exc:
            raise RuntimeError("后台进程记录损坏；未向任何进程发送信号。") from exc
        if (not isinstance(metadata, dict)
                or type(metadata.get("pid")) is not int or metadata["pid"] <= 1
                or type(metadata.get("port")) is not int or not 1 <= metadata["port"] <= 65535
                or not isinstance(metadata.get("token"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", metadata["token"])
                or not isinstance(metadata.get("script"), str)):
            raise RuntimeError("后台进程记录无效；未向任何进程发送信号。")
        return metadata

    def _save(self, metadata):
        fd, name = tempfile.mkstemp(prefix=".daemon-", dir=self.state_dir)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(metadata, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.metadata_path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def _matches(self, metadata):
        """同时检查仓库路径与每次启动生成的随机标记，避免 PID 重用误杀。"""
        if not metadata or metadata["script"] != self.script:
            return False
        result = subprocess.run(["/bin/ps", "-ww", "-p", str(metadata["pid"]), "-o", "command="],
                                capture_output=True, text=True, timeout=3, check=False)
        command = result.stdout.strip()
        return (result.returncode == 0
                and f" {self.script} " in f" {command} "
                and re.search(r"(?:^|\s)--daemon-token\s+" + re.escape(metadata["token"])
                              + r"(?:\s|$)", command) is not None)

    @staticmethod
    def _port_available(port):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                return False
        return True

    @staticmethod
    def _wait_ready(child, fd, timeout=10):
        deadline = time.monotonic() + timeout
        data = b""
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], min(0.1, max(0, deadline - time.monotonic())))
            if readable:
                chunk = os.read(fd, 64)
                if not chunk:
                    return False
                data += chunk
                if data == b"READY\n":
                    return child.poll() is None
                if len(data) > 64:
                    return False
            if child.poll() is not None:
                return False
        return False

    def status(self):
        # 状态查询不创建目录、锁文件或元数据。
        metadata = self._read()
        if metadata and self._matches(metadata):
            print(f"后台正在运行（PID {metadata['pid']}）：http://127.0.0.1:{metadata['port']}")
            print(f"日志：{self.log_path}")
            return 0
        print("Olanzi 后台未运行。" + ("原进程记录已失效；未影响其他进程。" if metadata else ""))
        return 1

    def start(self, port=8765, demo=False):
        with self._lock():
            metadata = self._read()
            if metadata and self._matches(metadata):
                print(f"后台已在运行：http://127.0.0.1:{metadata['port']}（PID {metadata['pid']}）")
                return 0
            if not self._port_available(port):
                print(f"端口 {port} 已被占用。请手动停止原服务，或用 --port 指定其他端口；未停止任何进程。")
                return 1
            self.log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            log_fd = os.open(self.log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
            read_fd = write_fd = None
            child = None
            try:
                read_fd, write_fd = os.pipe()
                os.fchmod(log_fd, 0o600)
                token = secrets.token_hex(32)
                command = [sys.executable, "-u", self.script, "--port", str(port), "--no-browser",
                           "--daemon-token", token, "--daemon-ready-fd", str(write_fd)]
                if demo:
                    command.append("--demo")
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log_fd, stderr=log_fd,
                                         cwd=str(Path(self.script).parent), start_new_session=True,
                                         close_fds=True, pass_fds=(write_fd,))
                os.close(write_fd)
                write_fd = None
                metadata = {"pid": child.pid, "port": port, "token": token, "script": self.script}
                self._save(metadata)
                if self._wait_ready(child, read_fd):
                    print(f"后台已启动：http://127.0.0.1:{port}（PID {child.pid}）")
                    print(f"日志：{self.log_path}")
                    return 0
                # 启动失败只清理本次创建的子进程，保留日志供定位；不使用 SIGKILL。
                if child.poll() is None:
                    child.send_signal(signal.SIGINT)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        print(f"后台未完成启动且尚未退出。请查看日志：{self.log_path}，然后运行 daemon stop。")
                        return 1
                self.metadata_path.unlink(missing_ok=True)
                print(f"后台启动失败，请查看日志：{self.log_path}")
                return 1
            except BaseException:
                # 元数据写入失败或父进程被中断时，不遗留无人管理的子进程。
                if child is not None and child.poll() is None:
                    child.send_signal(signal.SIGINT)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        print(f"新建后台尚未退出（PID {child.pid}），请查看日志：{self.log_path}")
                raise
            finally:
                os.close(log_fd)
                if read_fd is not None:
                    os.close(read_fd)
                if write_fd is not None:
                    os.close(write_fd)

    def stop(self):
        with self._lock():
            metadata = self._read()
            if not metadata:
                print("Olanzi 后台未运行。")
                return 0
            if not self._matches(metadata):
                print("原后台进程已退出或身份不匹配；未向其他进程发送信号。")
                self.metadata_path.unlink(missing_ok=True)
                return 0
            try:
                os.kill(metadata["pid"], signal.SIGINT)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if not self._matches(metadata):
                    self.metadata_path.unlink(missing_ok=True)
                    print("后台已停止，设备连接和心跳已关闭。")
                    return 0
                time.sleep(0.1)
            print(f"后台仍在退出中，未强制杀死进程。请查看日志：{self.log_path}，稍后再次运行 daemon stop。")
            return 1


def run_daemon(action, port=8765, demo=False):
    try:
        manager = DaemonManager()
        if action == "start":
            return manager.start(port, demo)
        if action == "stop":
            return manager.stop()
        if action == "status":
            return manager.status()
        raise ValueError("未知后台操作")
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"无法管理后台服务：{exc}", file=sys.stderr)
        return 1
