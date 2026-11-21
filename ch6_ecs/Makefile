# ch6_ecs — ECS 框架 Makefile
#
# 用法：
#   make          — 编译 C ECS（luaclib/ecs_high.so）
#   make test     — ECS 行为测试 + 性能基准
#   make bench    — 只跑性能基准
#   make clean    — 清理编译产物与日志
#
# 可用环境变量：
#   CH6_ENTITY_COUNT=1000   基准实体数
#   CH6_TICKS=1000          基准帧数

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch6

# ---- C ECS 编译 ----
CC       ?= gcc
LUA_INC  := $(SKYNET_ROOT)/3rd/lua
# OPT 可覆盖：make OPT="-O3 -march=native" bench
OPT      ?= -O2
CFLAGS   := $(OPT) -Wall -fPIC -I$(LUA_INC) -I$(CURDIR)/src
SHARED   := -shared
CSO      := luaclib/ecs_high.so

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: all test bench clean

all: $(CSO)

$(CSO): src/ecs_high.c src/ecs_high.h
	@mkdir -p luaclib
	$(CC) $(CFLAGS) $(SHARED) $< -o $@
	@echo "built: $@"

test: $(CSO)
	@echo "=== Running ECS tests + benchmark ==="
	$(MAKE) _run TEST_TARGET="test_ecs,bench_ecs" LOG_NAME=test

bench: $(CSO)
	@echo "=== Running ECS benchmark only ==="
	$(MAKE) _run TEST_TARGET=bench_ecs LOG_NAME=bench

_run:
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)
	@rm -f $(CURDIR)/ch6.log
	cd $(CURDIR) && \
		CH6_TEST_TARGET=$(TEST_TARGET) \
		CH6_ENTITY_COUNT=$(or $(CH6_ENTITY_COUNT),1000) \
		CH6_TICKS=$(or $(CH6_TICKS),1000) \
		$(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-$(LOG_NAME)/skynet.log ==="

clean:
	rm -rf $(CURDIR)/luaclib $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch6.log
	@echo "cleaned."
