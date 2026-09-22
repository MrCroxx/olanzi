"""协议确认、并发隔离和持久写入失败的回归验证。"""
import ctypes
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch
import unittest

from olanzi_device import (ALLOWED_CODES, DEFAULT_CODES, DemoTransport, DeviceController,
                           DeviceError, DeviceWorker, MacHIDTransport,
                           matches_reply, parse_entries, STUDIO_HEARTBEAT)


class RecordingTransport(DemoTransport):
    def __init__(self):
        super().__init__()
        self.requests = []
        self.threads = set()
        self.opened = self.closed = 0
        self.fail_index = None
        self.mismatch = False
        self.online = True
        self.keepalive_count = 0

    def open(self):
        super().open()
        self.opened += 1
        self.threads.add(threading.get_ident())

    def close(self):
        super().close()
        self.closed += 1
        self.threads.add(threading.get_ident())

    def keepalive(self):
        if self.heartbeat_enabled and time.monotonic() >= self.next_heartbeat:
            self.keepalive_count += 1
        super().keepalive()

    def query_online(self):
        return self.online

    def exchange(self, request, access, index, timeout=1.3):
        self.threads.add(threading.get_ident())
        self.requests.append(request)
        if access == 0x14 and index == self.fail_index:
            raise DeviceError("模拟写确认丢失")
        if access == 0x14 and self.mismatch:
            return bytes([0x81, 6, 0x50, access, index])
        return super().exchange(request, access, index, timeout)


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.transport = RecordingTransport()
        self.device = DeviceController(transport=self.transport)
        self.device.dispatch("connect")

    def payload(self, changes):
        return {"changes": [{"index": i, "code": c} for i, c in changes],
                "expected": [{"index": i, "entries": self.device.snapshot()["keys"][i]["entries"]}
                             for i, _c in changes]}

    def test_connect_reads_exactly_six_keys_without_writes(self):
        self.assertEqual(self.transport.requests, [bytes([1, 6, 0x50, 1, i]) for i in range(6)])
        self.assertEqual([k["code"] for k in self.device.snapshot()["keys"]], list(DEFAULT_CODES))
        self.assertIsNotNone(self.device.snapshot()["lastRead"])

    def test_write_requires_ack_and_readback(self):
        result = self.device.dispatch("apply", self.payload([(0, 0x68)]))
        self.assertEqual(result["keys"][0]["code"], 0x68)
        requests = self.transport.requests
        write = requests.index(bytes([1, 6, 0x50, 4, 0, 1, 1, 2, 0x68]))
        self.assertEqual(requests[write + 1], bytes([1, 6, 0x50, 1, 0]))
        self.assertTrue(all(r[3] == 1 or r[:4] == b"\x01\x06\x50\x04" for r in requests))

    def test_stale_conflict_prevents_every_write(self):
        payload = self.payload([(0, 0x68), (1, 0x69)])
        self.transport.keys[1] = [[2, 0x04]]
        with self.assertRaises(DeviceError) as error:
            self.device.dispatch("apply", payload)
        self.assertEqual(error.exception.status, 409)
        self.assertFalse(any(r[3] == 4 for r in self.transport.requests))
        self.assertEqual(self.device.snapshot()["keys"][1]["code"], 0x04)

    def test_partial_failure_reports_actual_readback(self):
        self.transport.fail_index = 1
        with self.assertRaisesRegex(DeviceError, "部分改动可能已生效"):
            self.device.dispatch("apply", self.payload([(0, 0x68), (1, 0x69)]))
        state = self.device.snapshot()
        self.assertEqual(state["keys"][0]["code"], 0x68)
        self.assertEqual(state["keys"][1]["code"], 0x28)
        self.assertTrue(state["connected"])
        self.assertIsNotNone(state["error"])

    def test_refresh_timeout_keeps_receiver_and_heartbeat_for_recovery(self):
        original = self.transport.exchange
        self.transport.exchange = lambda *_args, **_kwargs: (_ for _ in ()).throw(DeviceError("读取超时"))
        with self.assertRaises(DeviceError):
            self.device.dispatch("refresh")
        state = self.device.snapshot()
        self.assertTrue(state["connected"])
        self.assertIsNone(state["online"])
        self.assertTrue(state["heartbeat"]["enabled"])
        self.assertEqual(self.transport.closed, 0)
        self.transport.exchange = original
        self.device.dispatch("tick")
        self.assertTrue(self.device.snapshot()["online"])

    def test_failed_partial_readback_keeps_heartbeat_and_recovers_actual_keys(self):
        original = self.transport.exchange
        wrote = [False]

        def exchange(request, access, index, timeout=1.3):
            if access == 0x11 and wrote[0]:
                raise DeviceError("模拟本体暂时无回复")
            result = original(request, access, index, timeout)
            if access == 0x14:
                wrote[0] = True
            return result

        self.transport.exchange = exchange
        with self.assertRaisesRegex(DeviceError, "部分改动可能已生效"):
            self.device.dispatch("apply", self.payload([(0, 0x68), (1, 0x69)]))
        state = self.device.snapshot()
        self.assertTrue(state["connected"])
        self.assertIsNone(state["online"])
        self.assertTrue(state["heartbeat"]["enabled"])
        self.assertEqual(self.transport.closed, 0)
        self.transport.exchange = original
        self.device.dispatch("tick")
        state = self.device.snapshot()
        self.assertTrue(state["online"])
        self.assertEqual(state["keys"][0]["code"], 0x68)
        self.assertEqual(state["keys"][1]["code"], 0x28)

    def test_reconnect_status_timeout_does_not_keep_stale_online_flag(self):
        self.transport.query_online = lambda: (_ for _ in ()).throw(DeviceError("状态超时"))
        with self.assertRaises(DeviceError):
            self.device.dispatch("connect")
        self.assertTrue(self.device.snapshot()["connected"])
        self.assertIsNone(self.device.snapshot()["online"])

    def test_ack_without_actual_write_is_not_success(self):
        self.transport.mismatch = True
        with self.assertRaisesRegex(DeviceError, "回读与目标键码不一致"):
            self.device.dispatch("apply", self.payload([(0, 0x68)]))
        self.assertEqual(self.device.snapshot()["keys"][0]["code"], 1)

    def test_invalid_requests_never_write(self):
        payloads = [None, {}, {"changes": [], "expected": []}]
        for index, code in [(6, 0x68), (-1, 0x68), (True, 0x68), (0, True), (0, 2), (0, 256)]:
            payloads.append({"changes": [{"index": index, "code": code}],
                             "expected": [{"index": index, "entries": [[2, 1]]}]})
        payload = self.payload([(0, 0x68)])
        payload["changes"] *= 2
        payload["expected"] *= 2
        payloads.append(payload)
        for payload in payloads:
            with self.subTest(payload=payload), self.assertRaises(DeviceError) as error:
                self.device.dispatch("apply", payload)
            self.assertEqual(error.exception.status, 400)
        self.assertFalse(any(r[3] == 4 for r in self.transport.requests))

    def test_complex_existing_configuration_is_preserved(self):
        self.transport.keys[0] = [[0x82, 0xE0], [2, 4]]
        result = self.device.dispatch("refresh")
        self.assertIsNone(result["keys"][0]["code"])
        self.assertEqual(result["keys"][0]["entries"], [[0x82, 0xE0], [2, 4]])
        result = self.device.dispatch("apply", self.payload([(1, 0x68)]))
        self.assertEqual(result["keys"][0]["entries"], [[0x82, 0xE0], [2, 4]])

    def test_offline_dongle_is_not_confused_with_body(self):
        self.transport.online = False
        self.device.dispatch("tick")
        state = self.device.snapshot()
        self.assertTrue(state["connected"])
        self.assertFalse(state["online"])
        self.assertIsNone(state["heartbeat"]["lastReply"])
        self.assertIsNotNone(state["heartbeat"]["lastSent"])
        with self.assertRaises(DeviceError):
            self.device.dispatch("apply", self.payload([(0, 0x68)]))
        self.transport.online = True
        self.device.dispatch("tick")
        self.assertTrue(self.device.snapshot()["online"])

    def test_disconnect_stops_keepalive_and_clears_handles(self):
        self.device.dispatch("disconnect")
        before = self.transport.keepalive_count
        self.device.dispatch("tick")
        self.assertEqual(before, self.transport.keepalive_count)
        self.assertFalse(self.device.snapshot()["heartbeat"]["enabled"])
        self.assertIsNone(self.device.snapshot()["online"])
        self.assertEqual(self.transport.closed, 1)

    def test_body_recovers_after_status_timeout_without_closing_receiver(self):
        original = self.transport.query_online
        self.transport.query_online = lambda: (_ for _ in ()).throw(DeviceError("状态超时"))
        with self.assertRaises(DeviceError):
            self.device.dispatch("tick")
        self.assertTrue(self.device.snapshot()["connected"])
        self.assertIsNone(self.device.snapshot()["online"])
        self.transport.query_online = original
        self.device.dispatch("tick")
        self.assertTrue(self.device.snapshot()["online"])

    def test_frequent_api_reads_do_not_starve_heartbeat(self):
        transport = RecordingTransport()
        worker = DeviceWorker(transport=transport)
        try:
            worker.call("connect")
            deadline = time.monotonic() + 2.25
            while time.monotonic() < deadline:
                worker.call("state")
                time.sleep(0.015)
            self.assertGreaterEqual(transport.keepalive_count, 2)
        finally:
            worker.close()

    def test_deep_copy_keeps_ui_from_mutating_device(self):
        snapshot = self.device.snapshot()
        snapshot["keys"][0]["entries"][0][1] = 55
        self.assertEqual(self.device.snapshot()["keys"][0]["code"], 1)

    def test_safe_key_whitelist_matches_existing_tool(self):
        # AST 读取常量，避免测试在非 macOS 环境加载 IOKit。
        import ast
        from pathlib import Path
        tree = ast.parse((Path(__file__).resolve().parents[1] / "vibekey.py").read_text())
        keys = next(ast.literal_eval(node.value) for node in tree.body
                    if isinstance(node, ast.Assign) and any(
                        isinstance(target, ast.Name) and target.id == "KEYS" for target in node.targets))
        self.assertEqual(ALLOWED_CODES, frozenset(keys))

    def test_worker_serializes_native_calls_on_single_thread(self):
        transport = RecordingTransport()
        worker = DeviceWorker(transport=transport)
        try:
            status, _state = worker.call("connect")
            self.assertEqual(status, 200)
            threads = [threading.Thread(target=lambda: worker.call("refresh")) for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
        finally:
            worker.close()
        self.assertEqual(len(transport.threads), 1)
        self.assertNotIn(threading.get_ident(), transport.threads)
        self.assertEqual(transport.closed, 1)


class NativeLifecycleTests(unittest.TestCase):
    @staticmethod
    def fake_api(pages, open_error=0):
        events = []
        services = iter([*pages, 0])

        def enumerate_services(_port, matching, iterator):
            iterator._obj.value = 9
            events.append(("consume-matching", matching))
            return 0

        cf = SimpleNamespace(
            CFRelease=lambda ref: events.append(("release-cf", ref)),
            CFDictionarySetValue=lambda dictionary, key, value: events.append(("set-match", key, value)),
            CFRunLoopGetCurrent=lambda: 77)
        iok = SimpleNamespace(
            IOServiceMatching=lambda _name: 500,
            IOServiceGetMatchingServices=enumerate_services,
            IOIteratorNext=lambda _iterator: next(services),
            IOObjectRelease=lambda ref: events.append(("release-io", getattr(ref, "value", ref))),
            IOHIDDeviceCreate=lambda _allocator, service: service + 100,
            IOHIDDeviceOpen=lambda dev, _options: events.append(("open", dev)) or open_error,
            IOHIDDeviceClose=lambda dev, _options: events.append(("close", dev)) or 0,
            IOHIDDeviceRegisterInputReportCallback=lambda dev, buf, size, callback, context:
                events.append(("report-callback", dev, size)),
            IOHIDDeviceRegisterRemovalCallback=lambda dev, callback, context:
                events.append(("removal-callback", len(callback._argtypes_))),
            IOHIDDeviceScheduleWithRunLoop=lambda dev, runloop, mode:
                events.append(("schedule", dev, runloop)),
            IOHIDDeviceUnscheduleFromRunLoop=lambda dev, runloop, mode:
                events.append(("unschedule", dev, runloop)))
        report_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                                      ctypes.c_uint32, ctypes.c_uint32,
                                      ctypes.POINTER(ctypes.c_uint8), ctypes.c_long)
        api = SimpleNamespace(cf=cf, iok=iok, VIBE_VID=0xFFF1, VIBE_PID=0xDD,
                              VENDOR_USAGE_PAGE=0xFFFC, kCFAllocatorDefault=None,
                              kCFRunLoopDefaultMode=None, MAX_REPORT=1024, ReportCB=report_type,
                              cfnum=lambda value: value + 100000, cfstr=lambda value: value,
                              prop_int=lambda dev, _key: pages[dev - 100])
        return api, events

    def test_only_vendor_interface_opens_and_every_reference_is_released(self):
        api, events = self.fake_api({1: 1, 2: 0xFFFC, 3: 0xC})
        transport = MacHIDTransport()
        with patch.dict("sys.modules", {"vibekey": api}), patch("olanzi_device.sys.platform", "darwin"):
            transport.open()
            self.assertEqual([event for event in events if event[0] == "open"], [("open", 102)])
            self.assertIn(("removal-callback", 3), events)
            self.assertNotIn(("release-cf", 102), events)
            transport.close()
        for ref in (101, 102, 103, 0xFFF1 + 100000, 0xDD + 100000):
            self.assertEqual(events.count(("release-cf", ref)), 1)
        for ref in (1, 2, 3, 9):
            self.assertEqual(events.count(("release-io", ref)), 1)
        self.assertNotIn(("release-cf", 500), events)
        self.assertLess(events.index(("unschedule", 102, 77)), events.index(("close", 102)))
        self.assertLess(events.index(("close", 102)), events.index(("release-cf", 102)))
        self.assertIsNone(transport.dev)
        self.assertIsNone(transport.callback)
        self.assertIsNone(transport.removal_callback)

    def test_multiple_receivers_are_rejected_without_opening_any(self):
        api, events = self.fake_api({1: 0xFFFC, 2: 0xFFFC})
        with patch.dict("sys.modules", {"vibekey": api}), patch("olanzi_device.sys.platform", "darwin"):
            with self.assertRaisesRegex(DeviceError, "只连接一个"):
                MacHIDTransport().open()
        self.assertFalse(any(event[0] == "open" for event in events))
        self.assertIn(("release-cf", 101), events)
        self.assertIn(("release-cf", 102), events)

    def test_open_permission_failure_is_explicit_and_releases_device(self):
        api, events = self.fake_api({1: 0xFFFC}, 0xE00002E2)
        with patch.dict("sys.modules", {"vibekey": api}), patch("olanzi_device.sys.platform", "darwin"):
            with self.assertRaisesRegex(DeviceError, "无权限.*输入监控"):
                MacHIDTransport().open()
        self.assertIn(("release-cf", 101), events)
        self.assertFalse(any(event[0] == "schedule" for event in events))

    def test_exception_during_enumeration_releases_already_collected_candidates(self):
        api, events = self.fake_api({1: 0xFFFC, 2: 1})
        lookup = api.prop_int
        api.prop_int = lambda dev, key: lookup(dev, key) if dev == 101 else (
            (_ for _ in ()).throw(RuntimeError("模拟属性异常")))
        with patch.dict("sys.modules", {"vibekey": api}), patch("olanzi_device.sys.platform", "darwin"):
            with self.assertRaises(RuntimeError):
                MacHIDTransport().open()
        self.assertIn(("release-cf", 101), events)
        self.assertIn(("release-cf", 102), events)
        self.assertIn(("release-io", 9), events)


class ProtocolTests(unittest.TestCase):
    def test_reply_matching_rejects_wrong_command_group_access_and_index(self):
        good = bytes([0x81, 6, 0x50, 0x14, 2])
        self.assertTrue(matches_reply(good, 0x14, 2))
        for offset, value in [(0, 0x86), (1, 0x16), (2, 0x51), (3, 0x11), (4, 3)]:
            frame = bytearray(good)
            frame[offset] = value
            self.assertFalse(matches_reply(frame, 0x14, 2))
        for size in range(5):
            self.assertFalse(matches_reply(good[:size], 0x14, 2))

    def test_short_and_overlong_entry_tables_rejected(self):
        for frame in [b"", b"\x81\x06\x50\x11\0\1", bytes([0x81, 6, 0x50, 0x11, 0, 1, 25])]:
            with self.assertRaises(DeviceError):
                parse_entries(frame)

    def test_official_heartbeat_exact_bytes_and_long_exchange_cadence(self):
        transport = MacHIDTransport()
        transport.dev = 1
        transport.heartbeat_enabled = True
        clock = [0.0]
        sent = []
        plaintext = []

        def runloop(_mode, duration, _handled):
            clock[0] += duration

        transport.api = SimpleNamespace(
            tea_encrypt=lambda data: plaintext.append(data) or data,
            kCFRunLoopDefaultMode=None,
            cf=SimpleNamespace(CFRunLoopRunInMode=runloop),
            iok=SimpleNamespace(IOHIDDeviceSetReport=lambda dev, kind, rid, buf, size:
                                sent.append((clock[0], bytes(buf[:size]))) or 0))
        with patch("olanzi_device.time.monotonic", side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(DeviceError, "回复超时"):
                transport.exchange(bytes([1, 6, 0x50, 1, 0]), 0x11, 0, timeout=2.2)
        heartbeats = [(timestamp, wire) for timestamp, wire in sent if wire[1:6] == STUDIO_HEARTBEAT]
        self.assertEqual(len(heartbeats), 3)
        self.assertTrue(all(wire == b"\x55" + STUDIO_HEARTBEAT + bytes(58)
                            for _timestamp, wire in heartbeats))
        self.assertTrue(all(0.99 <= heartbeats[i][0] - heartbeats[i - 1][0] <= 1.03
                            for i in range(1, 3)))
        self.assertEqual(plaintext.count(STUDIO_HEARTBEAT + bytes(59)), 3)
        self.assertIsNotNone(transport.last_heartbeat_sent)

    def test_failed_heartbeat_does_not_claim_successful_send(self):
        transport = MacHIDTransport()
        transport.dev = 1
        transport.heartbeat_enabled = True
        transport.api = SimpleNamespace(tea_encrypt=lambda data: data,
                                       iok=SimpleNamespace(IOHIDDeviceSetReport=lambda *_args: 1))
        with self.assertRaises(DeviceError):
            transport.keepalive()
        self.assertIsNone(transport.last_heartbeat_sent)

    def test_native_exchange_discards_stale_and_unrelated_acks(self):
        transport = MacHIDTransport()
        transport.dev = 1
        sent = []
        transport.api = SimpleNamespace(
            tea_encrypt=lambda data: data,
            iok=SimpleNamespace(IOHIDDeviceSetReport=lambda dev, kind, rid, buf, size:
                                sent.append(bytes(buf[:size])) or 0))
        valid = bytes([0x81, 6, 0x50, 0x14, 2])
        transport.frames = [valid]
        calls = []

        def pump(_duration=0.01):
            calls.append(True)
            if len(calls) == 2:
                transport.frames.extend([b"", bytes([0x81, 6, 0x50, 0x11, 2]),
                                         bytes([0x81, 6, 0x50, 0x14, 3]), valid])

        transport.pump = pump
        result = transport.exchange(bytes([1, 6, 0x50, 4, 2, 1, 1, 2, 0x68]), 0x14, 2)
        self.assertEqual(result, valid)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(sent), 1)
        self.assertEqual(len(sent[0]), 64)
        self.assertEqual(sent[0][:10], bytes([0x55, 1, 6, 0x50, 4, 2, 1, 1, 2, 0x68]))

    def test_native_timeout_does_not_accept_other_control_reply(self):
        transport = MacHIDTransport()
        transport.dev = 1
        transport.api = SimpleNamespace(tea_encrypt=lambda data: data,
                                       iok=SimpleNamespace(IOHIDDeviceSetReport=lambda *_args: 0))
        transport.pump = lambda _duration=0.01: transport.frames.append(
            bytes([0x81, 6, 0x50, 0x14, 1]))
        with self.assertRaisesRegex(DeviceError, "回复超时"):
            transport.exchange(bytes([1, 6, 0x50, 4, 2, 1, 1, 2, 0x68]), 0x14, 2, timeout=0.005)

    def test_callback_only_decrypts_seven_complete_blocks(self):
        transport = MacHIDTransport()
        decrypted = []
        transport.api = SimpleNamespace(tea_decrypt=lambda data: decrypted.append(data) or data)
        wire = b"\x55" + bytes(range(63))
        report = (ctypes.c_uint8 * 64).from_buffer_copy(wire)
        transport._on_report(None, 0, None, 0, 0x55, report, 64)
        self.assertEqual(decrypted, [bytes(range(56))])
        self.assertIsNone(transport.callback_error)

    def test_callback_ignores_short_reports_and_exposes_exceptions(self):
        transport = MacHIDTransport()
        transport._on_report(None, 0, None, 0, 0x55, None, 4)
        self.assertEqual(transport.frames, [])
        self.assertIsNone(transport.callback_error)
        data = (ctypes.c_uint8 * 63)()
        transport._on_report(None, 0, None, 0, 0x55, data, 63)
        self.assertIn("HID 回调处理失败", transport.callback_error)


if __name__ == "__main__":
    unittest.main()
