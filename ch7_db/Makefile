# ch7_db — MySQL 数据库服务 Makefile
#
# 用法：
#   make test             — test_db + test_concurrency
#   make test-db          — 只跑 CRUD 与连接池
#   make test-concurrency — 只跑并发存盘安全（含对照实验）
#   make test-nq          — 关闭 queue 的对照（观察丢失更新）
#   make clean
#
# 环境变量：
#   CH7_DB_DRIVER=mysql   切换到真实 MySQL（需先建库表）
#   CH7_NO_QUEUE=1        关闭串行化（对照实验）
#   CH7_CONCURRENCY_N=20  并发数

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch7

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-db test-concurrency test-nq clean

test:
	@echo "=== Running db tests (CRUD + concurrency) ==="
	$(MAKE) _run TEST_TARGET="test_db,test_concurrency" LOG_NAME=test

test-db:
	@echo "=== Running db CRUD tests ==="
	$(MAKE) _run TEST_TARGET=test_db LOG_NAME=test_db

test-concurrency:
	@echo "=== Running concurrency safety tests ==="
	$(MAKE) _run TEST_TARGET=test_concurrency LOG_NAME=test_concurrency

# 对照实验：关闭 skynet.queue，应当观测到丢失更新
test-nq:
	@echo "=== CONTROL: concurrency WITHOUT queue (expect lost updates) ==="
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-test_nq
	@rm -f $(CURDIR)/ch7.log
	cd $(CURDIR) && \
		CH7_TEST_TARGET=test_concurrency CH7_NO_QUEUE=1 \
		CH7_DB_DRIVER=$(or $(CH7_DB_DRIVER),memory) \
		$(SKYNET) $(CONF) 2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-test_nq/skynet.log

_run:
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)
	@rm -f $(CURDIR)/ch7.log
	cd $(CURDIR) && \
		CH7_TEST_TARGET=$(TEST_TARGET) \
		CH7_NO_QUEUE=$(or $(CH7_NO_QUEUE),0) \
		CH7_DB_DRIVER=$(or $(CH7_DB_DRIVER),memory) \
		$(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log ==="

clean:
	rm -rf $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch7.log
	@echo "cleaned."
