# ch9_http — 服务器管理与 HTTP Makefile
#
# 用法：
#   make test   — HTTP 接口测试（35 断言）
#   make run    — 常驻，手动 curl 调试
#   make clean
#
# 环境变量：
#   CH9_GM_TOKEN=xxx          GM 接口令牌（默认 dev-token）
#   CH9_CALLBACK_SECRET=xxx   内部回调密钥（默认 dev-secret）
#   CH9_HTTP_PORT=8899        监听端口

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_PREFIX  := ch9

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test run clean

test:
	@echo "=== Running HTTP management interface tests ==="
	@mkdir -p $(CURDIR)/log/$(LOG_PREFIX)-test
	@rm -f $(CURDIR)/ch9.log
	cd $(CURDIR) && \
		CH9_TEST_TARGET=test_http \
		CH9_GM_TOKEN=$(or $(CH9_GM_TOKEN),dev-token) \
		CH9_CALLBACK_SECRET=$(or $(CH9_CALLBACK_SECRET),dev-secret) \
		CH9_HTTP_PORT=$(or $(CH9_HTTP_PORT),8899) \
		$(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/log/$(LOG_PREFIX)-test/skynet.log
	@echo ""
	@echo "=== Log: log/$(LOG_PREFIX)-test/skynet.log ==="

run:
	@echo "=== Starting http_mgr (no test) ==="
	@echo "=== curl http://127.0.0.1:$(or $(CH9_HTTP_PORT),8899)/health ==="
	cd $(CURDIR) && \
		CH9_GM_TOKEN=$(or $(CH9_GM_TOKEN),dev-token) \
		CH9_CALLBACK_SECRET=$(or $(CH9_CALLBACK_SECRET),dev-secret) \
		$(SKYNET) $(CONF)

clean:
	rm -rf $(CURDIR)/log/$(LOG_PREFIX)-*
	@rm -f $(CURDIR)/ch9.log
	@echo "cleaned."
