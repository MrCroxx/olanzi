#!/usr/bin/env python3
"""在本机启动 Olanzi 轻量设备工作台，无第三方依赖。"""
from __future__ import annotations

import argparse
import json
import mimetypes
import signal
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import webbrowser

from olanzi_device import DeviceWorker
from olanzi_settings import LocalSettings

WEB_ROOT = Path(__file__).resolve().parent / "web"
MAX_BODY = 8192
STATIC_FILES = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js",
                "/style.css": "style.css", "/keycodes.js": "keycodes.js",
                "/favicon.svg": "favicon.svg"}


class OlanziServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, worker, web_root=WEB_ROOT):
        self.worker = worker
        self.web_root = Path(web_root)
        super().__init__(address, OlanziHandler)


class OlanziHandler(BaseHTTPRequestHandler):
    server_version = "Olanzi/1.0"

    def log_message(self, _format, *_args):
        pass

    def _send(self, status, data, content_type="application/json; charset=utf-8"):
        if isinstance(data, dict):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; "
                         "style-src 'self'; img-src 'self' data:; connect-src 'self'; "
                         "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(data)

    def _valid_host(self):
        port = self.server.server_port
        return (len(self.headers.get_all("Host", [])) == 1
                and self.headers.get("Host") in (f"127.0.0.1:{port}", f"localhost:{port}"))

    def do_GET(self):
        if not self._valid_host():
            self._send(403, {"error": "只允许通过本机地址访问。"})
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            status, result = self.server.worker.call("state")
            self._send(status, result)
        elif path in STATIC_FILES:
            file = self.server.web_root / STATIC_FILES[path]
            if not file.is_file():
                self._send(404, {"error": "文件不存在。"})
                return
            mime = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
            self._send(200, file.read_bytes(), mime + "; charset=utf-8")
        else:
            self._send(404, {"error": "路径不存在。"})

    def do_POST(self):
        if (not self._valid_host()
                or len(self.headers.get_all("Origin", [])) != 1
                or self.headers.get("Origin") != f"http://{self.headers.get('Host')}"
                or self.headers.get("Sec-Fetch-Site") == "cross-site"):
            self._send(403, {"error": "拒绝跨站请求，请从本机配置页面操作。"})
            return
        if self.headers.get_content_type() != "application/json":
            self._send(415, {"error": "请求必须使用 application/json。"})
            return
        if self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) != 1:
            self._send(400, {"error": "无效的请求长度。"})
            return
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY:
            self._send(413, {"error": "请求体过大或长度无效。"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            self._send(400, {"error": "无效的 JSON 请求。"})
            return
        actions = {"/api/connect": "connect", "/api/disconnect": "disconnect",
                   "/api/refresh": "refresh", "/api/apply": "apply",
                   "/api/fn": "configure_fn", "/api/fn/permissions": "fn_permissions"}
        action = actions.get(self.path)
        if not action:
            self._send(404, {"error": "路径不存在。"})
            return
        if action not in ("apply", "configure_fn") and payload != {}:
            self._send(400, {"error": "此操作仅接受空 JSON 对象。"})
            return
        status, result = self.server.worker.call(action, payload)
        self._send(status, result)

    def do_OPTIONS(self):
        self._send(403, {"error": "不允许跨站访问。"})


def main():
    parser = argparse.ArgumentParser(description="Olanzi · 本地轻量设备工作台")
    parser.add_argument("mode", nargs="?", choices=("daemon",), help="手动管理后台服务")
    parser.add_argument("action", nargs="?", choices=("start", "stop", "status"))
    parser.add_argument("--port", type=int, default=8765, help="本机 HTTP 端口（默认 8765）")
    parser.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    parser.add_argument("--demo", action="store_true", help="使用独立演示设备，不访问硬件")
    parser.add_argument("--daemon-token", help=argparse.SUPPRESS)
    parser.add_argument("--daemon-ready-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("端口必须在 1–65535 之间")
    if args.mode == "daemon":
        if not args.action:
            parser.error("daemon 后需要 start、stop 或 status")
        from olanzi_daemon import run_daemon
        raise SystemExit(run_daemon(args.action, port=args.port, demo=args.demo))
    settings = LocalSettings(persistent=not args.demo)
    worker = DeviceWorker(demo=args.demo, fn_enabled=settings.fn_enabled,
                          save_fn=settings.save_fn, settings_error=settings.error,
                          auto_connect=True)
    try:
        server = OlanziServer(("127.0.0.1", args.port), worker)
    except OSError as exc:
        worker.close()
        parser.exit(1, f"无法启动本地服务：{exc}\n")
    url = f"http://127.0.0.1:{server.server_port}"
    print(f"Olanzi 已启动：{url}" + ("（演示模式，不访问硬件）" if args.demo else ""), flush=True)
    print("按 Ctrl-C 停止。", flush=True)
    if args.daemon_ready_fd is not None:
        from olanzi_daemon import notify_ready
        notify_ready(args.daemon_ready_fd)
    if not args.no_browser:
        webbrowser.open(url)
    def terminate(_signum, _frame):
        raise KeyboardInterrupt

    original_term = signal.signal(signal.SIGTERM, terminate)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        worker.close()
        signal.signal(signal.SIGTERM, original_term)


if __name__ == "__main__":
    main()
