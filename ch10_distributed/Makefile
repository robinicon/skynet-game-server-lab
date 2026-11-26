# ch10_distributed — 分布式登录与 Redis Makefile
#
# 用法：
#   make test        — 三进程（auth + center1 + center2）跨节点测试
#   make test-hang   — 对照组：证明裸 cluster.call 在目标假死时会挂死
#   make run         — 三节点常驻，手动调试
#   make clean
#
# 环境变量：
#   CH10_CALL_TIMEOUT=100   单次跨节点调用超时（cs，1cs=10ms）
#   CH10_CB_THRESHOLD=3     连续失败几次后熔断
#   CH10_CB_COOLDOWN=300    熔断冷却时长（cs）
#   CH10_CACHE_TTL=3000     gateway 本地 token 缓存时长（cs）
#   CH10_VNODES=128         一致性哈希虚拟节点数
#   CH10_REDIS_BACKEND=memory|redis
#   CH10_CENTERS=center1,center2

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-hang run clean

test:
	@echo "=== ch10_distributed: 三节点 cluster 跨进程测试 ==="
	@mkdir -p $(CURDIR)/log/test
	@rm -f $(CURDIR)/log/test/*.log $(CURDIR)/log/test/*.pid $(CURDIR)/node_*.log
	@cd $(CURDIR) && ( \
		$(SKYNET) conf/node_b.conf > log/test/node_b.log 2>&1 & echo $$! > log/test/node_b.pid ; \
		$(SKYNET) conf/node_c.conf > log/test/node_c.log 2>&1 & echo $$! > log/test/node_c.pid ; \
		sleep 0.5 ; \
		CH10_TEST_TARGET=test_cluster \
		$(SKYNET) conf/node_a.conf 2>&1 | tee log/test/node_a.log ; \
		rc=$${PIPESTATUS[0]} ; \
		kill $$(cat log/test/node_b.pid) $$(cat log/test/node_c.pid) 2>/dev/null ; \
		sleep 0.3 ; \
		echo "" ; \
		echo "--- center1(node_b) 日志尾部 ---" ; tail -n 4 log/test/node_b.log 2>/dev/null ; \
		echo "--- center2(node_c) 日志尾部 ---" ; tail -n 4 log/test/node_c.log 2>/dev/null ; \
		exit $$rc )

# 对照组：不做任何超时/熔断保护，直接 cluster.call 一个永不返回的服务
test-hang:
	@echo "=== 对照组：裸 cluster.call 在目标服务假死时的行为 ==="
	@mkdir -p $(CURDIR)/log/test
	@cd $(CURDIR) && ( \
		$(SKYNET) conf/node_b.conf > log/test/hang_b.log 2>&1 & echo $$! > log/test/hang_b.pid ; \
		sleep 0.5 ; \
		CH10_CENTERS=center1 CH10_TEST_TARGET=test_hang \
		timeout 15 $(SKYNET) conf/node_a.conf 2>&1 | tee log/test/hang_a.log ; \
		rc=$${PIPESTATUS[0]} ; \
		kill $$(cat log/test/hang_b.pid) 2>/dev/null ; \
		echo "" ; \
		if [ "$$rc" = "124" ]; then \
			echo "结论：裸 cluster.call 挂死 >= 15 秒，被 timeout 强杀（rc=124）" ; \
			echo "对照：make test 的 D3.1 用 dist_call 包装后，同样场景 1000ms 内返回 timeout，进程继续服务" ; \
			exit 0 ; \
		else \
			echo "[FAIL] 裸调用竟然返回了（rc=$$rc），对照组不成立" ; exit 1 ; \
		fi )

run:
	@echo "=== 三节点常驻（Ctrl-C 退出） ==="
	@mkdir -p $(CURDIR)/log
	@cd $(CURDIR) && ( \
		$(SKYNET) conf/node_b.conf > log/run_b.log 2>&1 & echo $$! > log/run_b.pid ; \
		$(SKYNET) conf/node_c.conf > log/run_c.log 2>&1 & echo $$! > log/run_c.pid ; \
		trap 'kill $$(cat log/run_b.pid) $$(cat log/run_c.pid) 2>/dev/null' EXIT ; \
		$(SKYNET) conf/node_a.conf )

clean:
	@rm -f $(CURDIR)/log/test/*.log $(CURDIR)/log/test/*.pid
	@rm -f $(CURDIR)/log/run_*.log $(CURDIR)/log/run_*.pid
	@rm -f $(CURDIR)/node_*.log
	@echo "cleaned."
