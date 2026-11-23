# ch8_components — 组件式编程 Makefile
#
# 用法：
#   make test   — 组件生命周期与消息路由测试
#   make clean

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch8

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test clean

test:
	@echo "=== Running component tests ==="
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-test
	@rm -f $(CURDIR)/ch8.log
	cd $(CURDIR) && \
		CH8_TEST_TARGET=test_components \
		$(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-test/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-test/skynet.log ==="

clean:
	rm -rf $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch8.log
	@echo "cleaned."
