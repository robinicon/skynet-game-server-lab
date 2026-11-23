# ch13_palace MySQL C 扩展编译
# 用法（WSL 内）：make -C clib
# 产物：clib/mysql.so，由 conf/skynet.conf 的 lua_cpath 加载

SKYNET_LUA := ../../skynet/3rd/lua
CFLAGS     := -O2 -fPIC -Wall -shared -I$(SKYNET_LUA) $(shell mysql_config --cflags)
LIBS       := $(shell mysql_config --libs)

all: mysql.so

mysql.so: mysql.c
	gcc $(CFLAGS) mysql.c -o mysql.so $(LIBS)
	@echo "built: clib/mysql.so"

clean:
	rm -f mysql.so

.PHONY: all clean
