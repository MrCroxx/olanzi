"""Fn 设置与设备通道、无人值守连接的集成验证。"""
import time
import unittest
from unittest.mock import Mock
from olanzi_device import DeviceController, DeviceWorker, DemoTransport, DeviceError
from olanzi_fn import FnBridge


class IntegrationTests(unittest.TestCase):
    def test_fn_toggle_does_not_write_device_and_persist_failure_keeps_old_setting(self):
        transport = DemoTransport()
        transport.exchange = Mock(wraps=transport.exchange)
        save = Mock()
        controller = DeviceController(demo=True, transport=transport, save_fn=save)
        controller.dispatch('connect')
        transport.exchange.reset_mock()
        state = controller.dispatch('configure_fn', {'enabled': True})
        save.assert_called_once_with(True)
        self.assertTrue(state['fnBridge']['enabled'])
        transport.exchange.assert_not_called()
        save.side_effect = OSError('disk full')
        with self.assertRaises(DeviceError):
            controller.dispatch('configure_fn', {'enabled': False})
        self.assertTrue(controller.snapshot()['fnBridge']['enabled'])

    def test_permission_denial_does_not_break_keys_or_heartbeat(self):
        backend = Mock()
        backend.permissions.return_value = (False, False)
        controller = DeviceController(demo=True, fn_bridge=FnBridge(backend=backend), fn_enabled=True)
        state = controller.dispatch('connect')
        self.assertTrue(state['online'])
        self.assertTrue(state['heartbeat']['enabled'])
        self.assertEqual(len(state['keys']), 6)
        self.assertFalse(state['fnBridge']['active'])
        self.assertIn('权限', state['fnBridge']['error'])
        backend.open.assert_not_called()
        backend.request_permissions.assert_not_called()
        controller.dispatch('fn_permissions')
        backend.request_permissions.assert_called_once()
        controller.disconnect()

    def test_autoconnect_explicit_disconnect_and_reconnect(self):
        worker = DeviceWorker(demo=True, auto_connect=True)
        try:
            self.assertTrue(worker.call('state')[1]['connected'])
            self.assertTrue(worker.call('state')[1]['heartbeat']['enabled'])
            worker.call('disconnect')
            time.sleep(0.25)
            self.assertFalse(worker.call('state')[1]['connected'])
            self.assertFalse(worker.want_connection)
            worker.call('connect')
            self.assertTrue(worker.call('state')[1]['connected'])
            self.assertTrue(worker.want_connection)
        finally:
            worker.close()

    def test_invalid_fn_setting_does_not_change_state(self):
        controller = DeviceController(demo=True)
        for payload in (None, {}, {'enabled': 1}, {'enabled': 'true'}, {'enabled': True, 'other': 1}):
            with self.subTest(payload=payload), self.assertRaises(DeviceError):
                controller.dispatch('configure_fn', payload)
            self.assertFalse(controller.snapshot()['fnBridge']['enabled'])
