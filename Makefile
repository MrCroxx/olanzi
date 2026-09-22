.DEFAULT_GOAL := help
export OLANZI_SIGNING_IDENTITY ?= auto

.PHONY: help dev build release dmg test check-docs

help:
	@echo "make dev         编译并打开 Debug 应用"
	@echo "make build       只编译 Debug 应用"
	@echo "make release     编译、签名 Release 应用并打包 DMG"
	@echo "make dmg         同 make release"
	@echo "make test        运行 Swift 测试"
	@echo "make check-docs  校验中英文文档"
	@echo "签名默认自动选择唯一证书；可设置 OLANZI_SIGNING_IDENTITY=证书名称"

# 依赖构建成功后再启动，避免编译失败时打开旧产物。
dev: build
	open "build/Olanzi.app"

build:
	./tools/build-macos.sh

release:
	./tools/build-macos.sh --release
	./tools/package-dmg.sh

dmg: release

test:
	swift test --package-path native

check-docs:
	python3 tools/check_docs.py
