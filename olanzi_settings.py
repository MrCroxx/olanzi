"""保存本机功能开关；与设备内的键位配置分开。"""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile


class LocalSettings:
    def __init__(self, path=None, persistent=True):
        self.path = Path(path) if path else Path.home() / 'Library/Application Support/Olanzi/settings.json'
        self.persistent = persistent
        self.fn_enabled = False
        self.error = None
        if persistent and self.path.exists():
            try:
                value = json.loads(self.path.read_text(encoding='utf-8'))
                if (not isinstance(value, dict) or value.get('version') != 1
                        or type(value.get('fnEnabled')) is not bool):
                    raise ValueError('设置格式不受支持')
                self.fn_enabled = value['fnEnabled']
            except (OSError, ValueError) as exc:
                self.error = f'无法读取本机设置，Fn 转换暂不启用：{exc}'

    def save_fn(self, enabled):
        if type(enabled) is not bool:
            raise ValueError('Fn 开关必须为布尔值')
        if self.persistent:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                                 dir=self.path.parent, prefix='.settings-',
                                                 delete=False) as stream:
                    temporary = Path(stream.name)
                    os.chmod(temporary, 0o600)
                    json.dump({'version': 1, 'fnEnabled': enabled}, stream)
                    stream.write('\n')
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
            finally:
                if temporary and temporary.exists():
                    temporary.unlink()
        self.fn_enabled = enabled
        self.error = None
