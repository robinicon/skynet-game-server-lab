# ch4_login — Skynet Lua 登录服务 Makefile
#
# 分层架构：
#   conf/     → 运行时配置
#   shared/   → 公共工具（error_code, token, utils, service）
#   proto/    → sproto 协议定义与编译
#   service/  → 业务服务（center, agent）
#   gateway/  → 入口层（main, gate, login）
#   test/     → 测试用例与压测
#
# 用法：
#   make run          — 启动服务（无测试，常驻监听 gate_port）
#   make test         — 运行全部单元测试（单进程，一次跑完）
#   make test-login   — 运行 T1/T2（单账号登录）
#   make test-center  — 运行 T3/T4/T7（并发保护 + Token 验证 + 指标）
#   make stress       — center 单点吞吐压测（不走网络）
#   make stress-e2e   — 端到端压测（TCP + 协议 + agent 创建）
#   make bench        — 依次跑 stress 与 stress-e2e
#   make clean        — 清理日志

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch4

# 用 bash + pipefail，保证 skynet 退出码能透过 tee 传递给 make
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: run test test-login test-center stress stress-e2e bench clean

# ============================================================
# run：纯启动，不跑测试
# ============================================================
run:
	@echo "=== Starting ch4_login service (no test, gate listening) ==="
	cd $(CURDIR) && $(SKYNET) $(CONF)

# ============================================================
# test：单进程跑完全部单元测试
#   （旧版每个用例启动一个 skynet 进程，进程启动开销被重复计入）
# ============================================================
test:
	@echo "=== Running unit tests (single process) ==="
	$(MAKE) _test TEST_TARGET="test_login,test_center" LOG_NAME=test

test-login:
	@echo "=== Running T1/T2: Login Unit Tests ==="
	$(MAKE) _test TEST_TARGET=test_login

test-center:
	@echo "=== Running T3/T4/T7: Center Tests ==="
	$(MAKE) _test TEST_TARGET=test_center

# ============================================================
# stress：center 单服务串行吞吐（不含网络与 agent 开销）
# ============================================================
stress:
	@echo "=== Running T5/T6: center throughput stress ==="
	$(MAKE) _test TEST_TARGET=stress_center

# ============================================================
# stress-e2e：端到端压测（真实链路，性能数字以此为准）
#   可用 CH4_E2E_COUNT 覆盖并发数：make stress-e2e CH4_E2E_COUNT=200
# ============================================================
stress-e2e:
	@echo "=== Running T8: end-to-end stress (TCP + proto + agent) ==="
	cd $(CURDIR) && mkdir -p log/$(LOG_PREFIX)-stress_e2e
	cd $(CURDIR) && CH4_TEST_TARGET=stress_e2e CH4_E2E_COUNT=$(or $(CH4_E2E_COUNT),1000) CH4_NO_AGENT=$(or $(CH4_NO_AGENT),0) $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-stress_e2e/skynet.log

bench: stress stress-e2e

# ============================================================
# _test：内部目标
#   测试目标经环境变量 CH4_TEST_TARGET 注入（skynet 不解析 --key=value）
#   多个目标用逗号分隔，由 main.lua 在同一进程内依次执行
# ============================================================
_test:
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-$(or $(LOG_NAME),$(TEST_TARGET))
	@rm -f $(CURDIR)/ch4.log
	cd $(CURDIR) && \
		CH4_TEST_TARGET=$(TEST_TARGET) $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-$(or $(LOG_NAME),$(TEST_TARGET))/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-$(or $(LOG_NAME),$(TEST_TARGET))/skynet.log ==="

# ============================================================
# clean
# ============================================================
clean:
	rm -rf $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch4.log
	@echo "cleaned."
