"""真实本机 HTTP 服务的同源保护与演示工作流验证。"""
import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path

from olanzi import OlanziServer
from olanzi_device import DeviceWorker


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        Path(cls.temp.name, "index.html").write_text("<title>Olanzi</title>")
        cls.worker = DeviceWorker(demo=True)
        cls.server = OlanziServer(("127.0.0.1", 0), cls.worker, cls.temp.name)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.server.server_port
        cls.origin = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.close()
        cls.temp.cleanup()

    def request(self, method, path, payload=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        body = json.dumps(payload) if payload is not None else None
        hdrs = {"Origin": self.origin, "Content-Type": "application/json"}
        hdrs.update(headers or {})
        conn.request(method, path, body, hdrs)
        response = conn.getresponse()
        data = response.read()
        result = json.loads(data) if response.getheader("Content-Type", "").startswith("application/json") else data
        status = response.status
        conn.close()
        return status, result

    def test_demo_roundtrip_and_disconnect(self):
        status, state = self.request("POST", "/api/connect", {})
        self.assertEqual(status, 200)
        self.assertTrue(state["demo"])
        self.assertTrue(state["connected"])
        self.assertTrue(state["online"])
        original = state["keys"][0]["entries"]
        status, state = self.request("POST", "/api/apply", {
            "changes": [{"index": 0, "code": 0x69}],
            "expected": [{"index": 0, "entries": original}]})
        self.assertEqual(status, 200)
        self.assertEqual(state["keys"][0]["code"], 0x69)
        status, state = self.request("POST", "/api/disconnect", {})
        self.assertEqual(status, 200)
        self.assertFalse(state["connected"])

    def test_rejects_cross_origin_host_and_null_origin(self):
        for headers in ({"Origin": "https://attacker.example"}, {"Origin": "null"},
                        {"Host": "attacker.example"}, {"Sec-Fetch-Site": "cross-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request("POST", "/api/connect", {}, headers)[0], 403)
        self.assertEqual(self.request("GET", "/api/state", headers={"Host": "attacker.example"})[0], 403)

    def test_rejects_missing_origin(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/api/connect", "{}", {"Content-Type": "application/json"})
        response = conn.getresponse()
        self.assertEqual(response.status, 403)
        response.read()
        conn.close()

    def test_rejects_non_json_and_large_request(self):
        self.assertEqual(self.request("POST", "/api/connect", {}, {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("POST", "/api/connect", {"padding": "x" * 9000})[0], 413)

    def test_invalid_apply_returns_structured_error(self):
        status, result = self.request("POST", "/api/apply", {"changes": []})
        self.assertEqual(status, 400)
        self.assertIn("error", result)
        self.assertIn("state", result)

    def test_paths_do_not_expose_source_or_allow_get_writes(self):
        for path in ("/../vibekey.py", "/%2e%2e/vibekey.py", "/olanzi.py", "/api/apply"):
            self.assertEqual(self.request("GET", path)[0], 404)
        self.assertEqual(self.request("GET", "/")[0], 200)


if __name__ == "__main__":
    unittest.main()
