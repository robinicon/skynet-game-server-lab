# ch11_jump — 分布式跳转 Makefile
#
# 用法：
#   make test   — node_a(gate+scene_a+test) + node_b(scene_b) 两节点跨进程测试
#   make run    — 两节点常驻，手动调试
#   make clean

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test run clean

test:
	@echo "=== ch11_jump: 两节点跨进程跳转测试 ==="
	@mkdir -p $(CURDIR)/log
	@rm -f $(CURDIR)/log/*.log
	@cd $(CURDIR) && ( \
		$(SKYNET) conf/node_b.conf > log/node_b.log 2>&1 & echo $$! > log/node_b.pid ; \
		sleep 0.5 ; \
		CH11_TEST_TARGET=test_jump \
		$(SKYNET) conf/node_a.conf 2>&1 | tee log/node_a.log ; \
		rc=$${PIPESTATUS[0]} ; \
		kill $$(cat log/node_b.pid) 2>/dev/null ; \
		sleep 0.3 ; \
		exit $$rc )

# run: 两节点常驻。CH11_TEST_TARGET=__none__ 让 node_a 跳过测试、进入常驻（conf 默认会跑 test_jump 后退出）
run:
	@echo "=== 两节点常驻（Ctrl-C 退出） ==="
	@mkdir -p $(CURDIR)/log
	@cd $(CURDIR) && ( \
		$(SKYNET) conf/node_b.conf > log/run_b.log 2>&1 & echo $$! > log/run_b.pid ; \
		trap 'kill $$(cat log/run_b.pid) 2>/dev/null' EXIT ; \
		CH11_TEST_TARGET=__none__ $(SKYNET) conf/node_a.conf )

clean:
	@rm -f $(CURDIR)/log/*.log $(CURDIR)/log/*.pid
	@echo "cleaned."
