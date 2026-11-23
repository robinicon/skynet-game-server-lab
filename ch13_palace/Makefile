# ch13_palace — 抽象数据 + 抽象消息最小工程
#
# 用法（WSL 内执行）：
#   make test                   — schema 校验 + 全部测试服务
#   make test-one T=test_schema — 只跑一个测试服务
#   make test-mysql             — MySQL 驱动往返测试（CH13_DB_DRIVER=mysql）
#   make run                    — 常驻模式（不跑测试）
#   make gen                    — 从 conf/schema.xlsx 重新生成 Lua 表
#   make check-schema           — 校验 Excel 与生成物是否同步
#   make xlsx-preview           — 打印 Excel 四张表内容（不修改）
#   make xlsx-init              — 从 schema.json 重建 Excel（仅在源表丢失时）
#   make gamedata               — 从 conf/gamedata.xlsx 生成游戏内容 Lua
#   make check-gamedata         — 校验 gamedata Excel 与生成物同步
#   make gamedata-preview       — 打印 gamedata 各表（不修改）
#   make reconcile              — 批次对账（docs/samples，memory 驱动）
#   make reconcile-mysql        — 批次对账（MySQL 驱动，验证持久化不改语义）
#   make verify                 — test + reconcile，批次门禁
#   make ws-smoke               — WebSocket 入口冒烟（需另开终端 make run）
#   make clean                  — 清理日志与快照

SKYNET_ROOT := ../skynet
SKYNET      := $(SKYNET_ROOT)/skynet
CONF        := conf/skynet.conf
LOG_DIR     := log/ch13
TARGET      ?= test_schema test_storage test_message test_login_flow test_gate test_reconnect test_delta_wire test_action_hero test_action_item test_action_mission test_ws_gate test_cross test_u4 test_u6

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c
PYTHON      := python3

.PHONY: test test-one test-cross test-u4 test-u6 test-mysql run gen check-schema xlsx-preview xlsx-init \
        gamedata check-gamedata gamedata-preview reconcile reconcile-mysql verify \
        ws-smoke clib clib-clean clean

clib:
	$(MAKE) -C clib

clib-clean:
	$(MAKE) -C clib clean

gen: gamedata
	$(PYTHON) tools/gen_schema.py

check-schema: check-gamedata
	$(PYTHON) tools/check_schema.py

gamedata:
	$(PYTHON) tools/gen_gamedata.py

check-gamedata:
	$(PYTHON) tools/gen_gamedata.py --check

gamedata-preview:
	$(PYTHON) tools/make_gamedata_xlsx.py --stdout

reconcile: gen check-schema clib
	$(PYTHON) tools/compare_with_java.py --batch all --driver memory

reconcile-mysql: gen check-schema clib
	$(PYTHON) tools/compare_with_java.py --batch all --driver mysql

# 批次门禁：测试 + 对账都必须过，才允许进入下一批
verify: test reconcile

xlsx-preview:
	$(PYTHON) tools/make_xlsx.py --stdout

xlsx-init:
	$(PYTHON) tools/make_xlsx.py --force
	$(PYTHON) tools/gen_schema.py

test: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	@rm -f $(CURDIR)/data/test-snapshot.json $(CURDIR)/data/test-hub-snapshot.json
	cd $(CURDIR) && CH13_SNAPSHOT="data/test-snapshot.json" CH13_HUB_SNAPSHOT="data/test-hub-snapshot.json" CH13_TEST_TARGET="$(TARGET)" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet.log

test-one: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	@rm -f $(CURDIR)/data/test-snapshot.json $(CURDIR)/data/test-hub-snapshot.json
	cd $(CURDIR) && CH13_SNAPSHOT="data/test-snapshot.json" CH13_HUB_SNAPSHOT="data/test-hub-snapshot.json" CH13_TEST_TARGET="$(T)" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet-$(T).log

# P0.5：跨服 hub 最小链路单测（4 条断言 + 端到端动作）
test-cross: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	@rm -f $(CURDIR)/data/test-snapshot.json $(CURDIR)/data/test-hub-snapshot.json
	cd $(CURDIR) && CH13_SNAPSHOT="data/test-snapshot.json" CH13_HUB_SNAPSHOT="data/test-hub-snapshot.json" CH13_TEST_TARGET="test_cross" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet-test_cross.log

# U4：战斗与关卡批次单测（10 连打 / 战斗结算 / 商店 / 签到在线）
test-u4: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	@rm -f $(CURDIR)/data/test-snapshot.json $(CURDIR)/data/test-hub-snapshot.json
	cd $(CURDIR) && CH13_SNAPSHOT="data/test-snapshot.json" CH13_HUB_SNAPSHOT="data/test-hub-snapshot.json" CH13_TEST_TARGET="test_u4" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet-test_u4.log

test-u6: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	@rm -f $(CURDIR)/data/test-snapshot.json $(CURDIR)/data/test-hub-snapshot.json
	cd $(CURDIR) && CH13_SNAPSHOT="data/test-snapshot.json" CH13_HUB_SNAPSHOT="data/test-hub-snapshot.json" CH13_TEST_TARGET="test_u6" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet-test_u6.log

test-mysql: gen check-schema clib
	@mkdir -p $(CURDIR)/$(LOG_DIR) $(CURDIR)/data
	cd $(CURDIR) && CH13_DB_DRIVER=mysql CH13_SNAPSHOT="data/test-snapshot.json" \
		CH13_TEST_TARGET="test_mysql_roundtrip" $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/skynet-mysql.log

# P0：WebSocket 入口冒烟。需先另开终端 `make run`（或让服务常驻）后再执行。
#   make ws-smoke
#   make ws-smoke WS_URL=ws://192.168.1.10:9814 WS_ACCOUNT=demo WS_PASSWORD=p
WS_URL      ?= ws://127.0.0.1:9814
WS_ACCOUNT  ?= dev_ws
WS_PASSWORD ?= p
ws-smoke:
	node tools/ws_smoke.mjs $(WS_URL) $(WS_ACCOUNT) $(WS_PASSWORD)

run: gen check-schema
	@mkdir -p $(CURDIR)/$(LOG_DIR)
	cd $(CURDIR) && CH13_TEST_TARGET=__none__ $(SKYNET) $(CONF) \
		2>&1 | tee $(CURDIR)/$(LOG_DIR)/run.log

clean:
	rm -rf $(CURDIR)/log/ch13-*
	@rm -f $(CURDIR)/data/snapshot.json
	@echo cleaned.
