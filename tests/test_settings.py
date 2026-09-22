"""本机开关持久化和演示隔离。"""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from olanzi_settings import LocalSettings


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'settings.json'

    def test_persist_and_reload_both_states(self):
        settings = LocalSettings(self.path)
        self.assertFalse(settings.fn_enabled)
        for enabled in (True, False):
            settings.save_fn(enabled)
            self.assertIs(LocalSettings(self.path).fn_enabled, enabled)
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_demo_neither_reads_nor_writes_real_settings(self):
        self.path.write_text('{"version":1,"fnEnabled":true}')
        settings = LocalSettings(self.path, persistent=False)
        self.assertFalse(settings.fn_enabled)
        settings.save_fn(False)
        self.assertTrue(json.loads(self.path.read_text())['fnEnabled'])

    def test_corrupt_file_fails_closed(self):
        for value in ('{', 'null', '{"version":1,"fnEnabled":1}', '{"version":2,"fnEnabled":true}'):
            self.path.write_text(value)
            settings = LocalSettings(self.path)
            self.assertFalse(settings.fn_enabled)
            self.assertIsNotNone(settings.error)

    def test_failed_atomic_replace_preserves_previous_setting(self):
        settings = LocalSettings(self.path)
        settings.save_fn(False)
        with patch('olanzi_settings.os.replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                settings.save_fn(True)
        self.assertFalse(settings.fn_enabled)
        self.assertFalse(LocalSettings(self.path).fn_enabled)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])
