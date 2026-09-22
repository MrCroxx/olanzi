"""Mac Fn 桥接回归：全部使用替身，不向当前桌面发送按键。"""
import ctypes
import types
import unittest
from unittest.mock import Mock, patch

from olanzi_fn import FnBridge, MacFnBackend, FN_FLAG, decode_fn_report, fn_event_flags


PRESS = bytes([0, 0, 1, 0, 0, 0, 0, 0])
RELEASE = bytes(8)


class FakeBackend:
    def __init__(self):
        self.permission = (True, True)
        self.posted = []
        self.opened = False
        self.opens = self.closes = self.requests = 0
        self.fail_up = False
        self.fail_open = False

    def permissions(self):
        return self.permission

    def request_permissions(self):
        self.requests += 1

    def open(self, on_report, on_lost):
        if self.fail_open:
            raise RuntimeError("测试输入接口不可用")
        self.on_report, self.on_lost = on_report, on_lost
        self.opened = True
        self.opens += 1

    def close(self):
        self.opened = False
        self.closes += 1

    def post_fn(self, pressed):
        if not pressed and self.fail_up:
            raise RuntimeError("测试释放失败")
        self.posted.append(pressed)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.native = FakeBackend()
        self.bridge = FnBridge(backend=self.native)
        self.bridge.set_enabled(True)
        self.bridge.synchronize(True, True)

    def test_hold_duplicate_and_release(self):
        self.native.on_report(3, PRESS)
        self.native.on_report(3, PRESS)
        self.assertTrue(self.bridge.snapshot()["pressed"])
        self.native.on_report(3, RELEASE)
        self.native.on_report(3, RELEASE)
        self.assertEqual(self.native.posted, [True, False])
        self.assertEqual(self.bridge.snapshot()["events"], 2)

    def test_wrong_report_does_not_release_held_key(self):
        self.native.on_report(3, PRESS)
        for report_id, data in [(1, RELEASE), (0x55, RELEASE), (3, bytes(7)),
                                (3, b"\x02" + RELEASE)]:
            self.native.on_report(report_id, data)
        self.assertEqual(self.native.posted, [True])
        self.native.on_report(3, b"\x03" + RELEASE)
        self.assertEqual(self.native.posted, [True, False])

    def test_rollover_never_presses_and_releases_previous_hold(self):
        rollover = bytes([0, 0, 1, 1, 1, 1, 1, 1])
        self.native.on_report(3, rollover)
        self.assertEqual(self.native.posted, [])
        self.native.on_report(3, PRESS)
        self.native.on_report(3, rollover)
        self.assertEqual(self.native.posted, [True, False])

    def test_disable_offline_unknown_disconnect_and_shutdown_release(self):
        for operation in (lambda b: b.set_enabled(False), lambda b: b.synchronize(True, False),
                          lambda b: b.synchronize(True, None), lambda b: b.synchronize(False, None),
                          lambda b: b.close()):
            backend = FakeBackend()
            bridge = FnBridge(backend=backend)
            bridge.set_enabled(True)
            bridge.synchronize(True, True)
            backend.on_report(3, PRESS)
            operation(bridge)
            self.assertEqual(backend.posted, [True, False])
            self.assertFalse(bridge.snapshot()["active"])
            self.assertFalse(bridge.snapshot()["pressed"])
            self.assertEqual(backend.closes, 1)

    def test_removal_and_callback_failure_release_without_throwing(self):
        self.native.on_report(3, PRESS)
        self.native.on_lost("设备拔出")
        self.assertEqual(self.native.posted, [True, False])
        self.bridge.pump()
        self.assertFalse(self.bridge.snapshot()["active"])
        self.assertIn("拔出", self.bridge.snapshot()["error"])
        self.assertEqual(self.native.closes, 1)

    def test_bad_report_object_is_contained(self):
        self.native.on_report(3, PRESS)
        self.native.on_report(3, None)
        self.assertEqual(self.native.posted, [True, False])
        self.assertIn("报文处理失败", self.bridge.snapshot()["error"])

    def test_permission_denial_and_retry_no_automatic_prompts(self):
        self.bridge.close()
        self.native.permission = (False, False)
        self.bridge.synchronize(True, True)
        self.assertFalse(self.bridge.snapshot()["active"])
        self.assertFalse(self.bridge.snapshot()["inputPermission"])
        self.assertEqual(self.native.requests, 0)
        self.native.permission = (True, True)
        self.bridge.set_enabled(True)
        self.assertTrue(self.bridge.snapshot()["active"])
        self.bridge.request_permissions()
        self.assertEqual(self.native.requests, 1)

    def test_permissions_revoked_while_held_release_and_close(self):
        self.native.on_report(3, PRESS)
        self.native.permission = (True, False)
        self.bridge._next_retry = 0
        self.bridge.pump()
        self.assertEqual(self.native.posted, [True, False])
        self.assertFalse(self.native.opened)
        self.assertFalse(self.bridge.snapshot()["accessibilityPermission"])

    def test_failed_release_is_retried_before_closing_event_source(self):
        self.native.on_report(3, PRESS)
        self.native.fail_up = True
        self.bridge.set_enabled(False)
        self.assertTrue(self.bridge.snapshot()["pressed"])
        self.assertTrue(self.native.opened)
        self.assertIn("松开", self.bridge.snapshot()["error"])
        self.native.fail_up = False
        self.bridge.pump()
        self.assertFalse(self.bridge.snapshot()["pressed"])
        self.assertFalse(self.native.opened)
        self.assertEqual(self.native.posted, [True, False])

    def test_close_retries_transient_release_before_worker_exit(self):
        self.native.on_report(3, PRESS)
        original_post = self.native.post_fn
        attempts = []

        def fail_once(pressed):
            attempts.append(pressed)
            if not pressed and len(attempts) == 1:
                raise RuntimeError("一次性释放失败")
            original_post(pressed)

        self.native.post_fn = fail_once
        state = self.bridge.close()
        self.assertEqual(attempts, [False, False])
        self.assertEqual(self.native.posted, [True, False])
        self.assertFalse(state["pressed"])
        self.assertFalse(self.native.opened)
        self.assertEqual(self.native.closes, 1)

    def test_close_persistent_release_failure_is_bounded_and_visible(self):
        self.native.on_report(3, PRESS)
        self.native.post_fn = Mock(side_effect=RuntimeError("持续释放失败"))
        state = self.bridge.close()
        self.assertEqual(self.native.post_fn.call_count, 3)
        self.assertTrue(state["pressed"])
        self.assertIn("松开", state["error"])
        self.assertTrue(self.native.opened)

    def test_reports_after_removal_or_disable_cannot_repress_fn(self):
        self.native.on_report(3, PRESS)
        self.native.on_lost("设备断开")
        self.native.on_report(3, PRESS)
        self.bridge.set_enabled(False)
        self.native.on_report(3, PRESS)
        self.assertEqual(self.native.posted, [True, False])
        self.assertFalse(self.bridge.snapshot()["pressed"])

    def test_open_error_isolated_and_explicit_retry(self):
        self.bridge.close()
        self.native.fail_open = True
        self.bridge.synchronize(True, True)
        self.assertIn("不可用", self.bridge.snapshot()["error"])
        self.native.fail_open = False
        self.bridge.set_enabled(True)
        self.assertTrue(self.bridge.snapshot()["active"])

    def test_no_idle_timeout_cuts_off_long_press(self):
        self.native.on_report(3, PRESS)
        with patch("olanzi_fn.time.monotonic", return_value=1e12):
            self.bridge.pump()
        self.assertEqual(self.native.posted, [True])
        self.assertTrue(self.bridge.snapshot()["pressed"])

    def test_disabled_and_demo_never_load_native_libraries(self):
        with patch("olanzi_fn.MacFnBackend", side_effect=AssertionError("不应访问硬件")):
            bridge = FnBridge()
            bridge.synchronize(True, True)
            bridge.pump()
            bridge.close()
            demo = FnBridge(demo=True)
            demo.set_enabled(True)
            demo.synchronize(True, True)
            demo.request_permissions()
            demo.close()
            self.assertEqual(demo.snapshot()["events"], 0)
            self.assertFalse(demo.snapshot()["active"])


class NativeBoundaryTests(unittest.TestCase):
    def make_backend(self):
        backend = MacFnBackend.__new__(MacFnBackend)
        backend.dev, backend.source, backend.runloop = 10, 20, 30
        backend.scheduled = True
        backend.buf = backend.callback = backend.removal_callback = object()
        backend.on_report, backend.on_lost = Mock(), Mock()
        backend.callback_error = None
        backend.cg = Mock()
        backend.cg.CGEventCreateKeyboardEvent.return_value = 40
        backend.api = types.SimpleNamespace(cf=Mock(), iok=Mock(), kCFRunLoopDefaultMode=50)
        return backend

    def test_only_au05_input_interfaces_match(self):
        match = MacFnBackend.matches_device
        self.assertTrue(match(0xFFF1, 0xDD, 12, 1))
        self.assertTrue(match(0xFFF1, 0xDD, 1, 6))
        self.assertFalse(match(0xFFF1, 0xDD, 0xFFFC, 1))
        self.assertFalse(match(0x5AC, 0xDD, 1, 6))
        self.assertFalse(match(0xFFF1, 0xDE, 12, 1))

    def test_native_callback_filters_sender_type_and_length(self):
        backend = self.make_backend()
        report = (ctypes.c_uint8 * 8).from_buffer_copy(PRESS)
        for sender, kind, rid, length in ((11, 0, 3, 8), (10, 1, 3, 8),
                                          (10, 0, 1, 8), (10, 0, 3, 100)):
            backend._on_report(None, 0, sender, kind, rid, report, length)
        backend.on_report.assert_not_called()
        backend._on_report(None, 0, 10, 0, 3, report, 8)
        backend.on_report.assert_called_once_with(3, PRESS)

    def test_native_callback_catches_consumer_exceptions_and_io_errors(self):
        backend = self.make_backend()
        backend.on_report.side_effect = RuntimeError("回调测试失败")
        backend.on_lost.side_effect = RuntimeError("二次异常")
        report = (ctypes.c_uint8 * 8).from_buffer_copy(PRESS)
        backend._on_report(None, 0, 10, 0, 3, report, 8)
        self.assertIn("回调测试失败", backend.callback_error)
        backend._on_report(None, 1, 10, 0, 3, report, 8)
        self.assertIn("0x00000001", backend.callback_error)
        backend._on_remove(None, 0, 10)
        self.assertIn("断开", backend.callback_error)

    def test_stale_native_removal_cannot_remove_a_new_device_handle(self):
        backend = self.make_backend()
        backend._on_remove(None, 0, 11)
        backend.on_lost.assert_not_called()
        backend.dev = None
        backend._on_remove(None, 0, 10)
        backend.on_lost.assert_not_called()

    def test_fn_events_preserve_hardware_modifiers_and_physical_fn(self):
        backend = self.make_backend()
        for hardware in (0, 0x100000 | 0x20000, 0x20000000 | FN_FLAG):
            for pressed in (True, False):
                backend.cg.reset_mock()
                backend.cg.CGEventSourceFlagsState.return_value = hardware
                backend.post_fn(pressed)
                backend.cg.CGEventSourceFlagsState.assert_called_once_with(1)
                backend.cg.CGEventCreateKeyboardEvent.assert_called_once_with(20, 63, pressed)
                backend.cg.CGEventSetType.assert_called_once_with(40, 12)
                backend.cg.CGEventSetFlags.assert_called_once_with(
                    40, hardware | FN_FLAG if pressed else hardware)
                backend.cg.CGEventPost.assert_called_once_with(1, 40)
        self.assertEqual(fn_event_flags(FN_FLAG, False), FN_FLAG)

    def test_event_is_released_even_if_post_fails(self):
        backend = self.make_backend()
        backend.cg.CGEventSourceFlagsState.return_value = 0
        backend.cg.CGEventPost.side_effect = RuntimeError("发送失败")
        with self.assertRaises(RuntimeError):
            backend.post_fn(True)
        backend.api.cf.CFRelease.assert_called_once_with(40)

    def test_close_unregisters_three_argument_removal_and_releases_all(self):
        backend = self.make_backend()
        backend.close()
        backend.api.iok.IOHIDDeviceRegisterInputReportCallback.assert_called_once_with(
            10, None, 0, None, None)
        backend.api.iok.IOHIDDeviceRegisterRemovalCallback.assert_called_once_with(10, None, None)
        backend.api.iok.IOHIDDeviceUnscheduleFromRunLoop.assert_called_once_with(10, 30, 50)
        self.assertEqual([call.args[0] for call in backend.api.cf.CFRelease.call_args_list], [10, 20])
        self.assertIsNone(backend.callback)
        backend.close()
        self.assertEqual(backend.api.cf.CFRelease.call_count, 2)

    def test_cleanup_continues_after_native_close_failure(self):
        backend = self.make_backend()
        backend.api.iok.IOHIDDeviceClose.side_effect = RuntimeError("关闭失败")
        with self.assertRaisesRegex(RuntimeError, "资源清理失败"):
            backend.close()
        self.assertEqual([call.args[0] for call in backend.api.cf.CFRelease.call_args_list], [10, 20])
        self.assertIsNone(backend.dev)
        self.assertIsNone(backend.source)

    def test_native_open_releases_candidate_when_permission_denied(self):
        backend = self.make_backend()
        backend.dev = backend.source = None
        backend._candidates = Mock(return_value=[10])
        backend.api.iok.IOHIDDeviceOpen.return_value = 0xE00002E2
        with self.assertRaisesRegex(RuntimeError, "输入监控"):
            backend.open(Mock(), Mock())
        backend.api.cf.CFRelease.assert_called_once_with(10)
        backend.api.iok.IOHIDDeviceScheduleWithRunLoop.assert_not_called()

    def test_native_open_rejects_multiple_receivers_and_releases_them(self):
        backend = self.make_backend()
        backend.dev = backend.source = None
        backend._candidates = Mock(return_value=[10, 11])
        with self.assertRaisesRegex(RuntimeError, "恰好一个"):
            backend.open(Mock(), Mock())
        self.assertEqual([call.args[0] for call in backend.api.cf.CFRelease.call_args_list], [10, 11])
        backend.api.iok.IOHIDDeviceOpen.assert_not_called()

    def test_native_open_cleans_up_on_event_source_creation_failure(self):
        backend = self.make_backend()
        backend.dev = backend.source = None
        backend.scheduled = False
        backend._candidates = Mock(return_value=[10])
        backend.api.iok.IOHIDDeviceOpen.return_value = 0
        backend.cg.CGEventSourceCreate.return_value = None
        with self.assertRaisesRegex(RuntimeError, "事件源"):
            backend.open(Mock(), Mock())
        backend.cg.CGEventSourceCreate.assert_called_once_with(-1)
        backend.api.iok.IOHIDDeviceClose.assert_called_once_with(10, 0)
        backend.api.cf.CFRelease.assert_called_once_with(10)
        self.assertIsNone(backend.dev)

    def test_enumeration_filters_other_devices_and_balances_references(self):
        backend = self.make_backend()
        api = backend.api
        api.kCFAllocatorDefault = None
        api.cfstr = lambda value: value
        api.cfnum = Mock(side_effect=[101, 102])
        api.iok.IOServiceMatching.return_value = 100

        def matching(_port, _matching, iterator):
            iterator._obj.value = 200
            return 0

        api.iok.IOServiceGetMatchingServices.side_effect = matching
        api.iok.IOIteratorNext.side_effect = [201, 202, 203, 0]
        api.iok.IOHIDDeviceCreate.side_effect = [301, 302, 303]
        properties = {301: (0xFFF1, 0xDD, 12, 1), 302: (0xFFF1, 0xDD, 0xFFFC, 1),
                      303: (0x5AC, 0xDD, 1, 6)}
        fields = ("VendorID", "ProductID", "PrimaryUsagePage", "PrimaryUsage")
        api.prop_int = lambda device, name: properties[device][fields.index(name)]
        self.assertEqual(backend._candidates(), [301])
        self.assertEqual([call.args[0] for call in api.cf.CFRelease.call_args_list],
                         [101, 102, 302, 303])
        releases = [call.args[0] for call in api.iok.IOObjectRelease.call_args_list]
        self.assertEqual(releases[:3], [201, 202, 203])
        self.assertEqual(releases[3].value, 200)

    def test_parser_accepts_prefixed_report_and_rejects_error_codes(self):
        self.assertTrue(decode_fn_report(3, b"\x03" + PRESS))
        self.assertFalse(decode_fn_report(3, bytes([0, 0, 1, 2, 0, 0, 0, 0])))
        self.assertFalse(decode_fn_report(3, bytes([0, 0, 1, 1, 0, 0, 0, 0])))
        self.assertIsNone(decode_fn_report(3, bytes([0, 1, 1, 0, 0, 0, 0, 0])))


if __name__ == "__main__":
    unittest.main()
