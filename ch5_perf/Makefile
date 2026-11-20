# ch5_perf — 性能优化与对象池 Makefile
#
# 用法：
#   make test    — 对象池正确性测试（18 组用例 / 59 个断言）
#   make bench   — 池化 vs 非池化基准 + 函数级 profiling
#   make all     — test + bench
#   make clean   — 清理日志
#
# 可用环境变量覆盖：
#   CH5_BENCH_ROUNDS=100000   基准循环次数
#   CH5_BENCH_HOLD=64         场景B 同时持有对象数

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch5

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test bench all clean

test:
	@echo "=== Running pool unit tests (18 groups / 59 assertions) ==="
	$(MAKE) _run TEST_TARGET=test_pool LOG_NAME=test

bench:
	@echo "=== Running pool benchmark + profiling ==="
	$(MAKE) _run TEST_TARGET=bench_pool LOG_NAME=bench

all: test bench

_run:
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)
	@rm -f $(CURDIR)/ch5.log
	cd $(CURDIR) && \
		CH5_TEST_TARGET=$(TEST_TARGET) \
		CH5_BENCH_ROUNDS=$(or $(CH5_BENCH_ROUNDS),100000) \
		CH5_BENCH_HOLD=$(or $(CH5_BENCH_HOLD),64) \
		$(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log ==="

clean:
	rm -rf $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch5.log
	@echo "cleaned."
