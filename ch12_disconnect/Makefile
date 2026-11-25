# ch12_disconnect — 断线重连 + 热更新 Makefile
#
# 本议题是单节点（无 cluster），一次进程内跑完所有用例，无后台进程、无 WSL 多进程陷阱。
#
# 用法：
#   make test   — 单进程跑 test_all（T1–T5，断线重连 + 热更新）
#   make run    — 常驻，手动调试
#   make clean

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet

# 用 bash + pipefail，保证 skynet 退出码能透过 tee 传递（否则测试失败也返回 0）
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test run clean

test:
	@echo "=== ch12_disconnect: 单节点断线重连 + 热更新测试 ==="
	@mkdir -p $(CURDIR)/log
	@rm -f $(CURDIR)/log/*.log
	@cd $(CURDIR) && $(SKYNET) conf/node.conf 2>&1 | tee log/node.log

# run: CH12_TEST_TARGET=__none__ 让进程常驻（conf 默认 test_target=test_all 会在跑完测试后 exit）
run:
	@mkdir -p $(CURDIR)/log
	@cd $(CURDIR) && CH12_TEST_TARGET=__none__ $(SKYNET) conf/node.conf

clean:
	@rm -f $(CURDIR)/log/*.log
	@echo "cleaned."
