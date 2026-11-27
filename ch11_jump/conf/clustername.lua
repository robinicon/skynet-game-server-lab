-- conf/clustername.lua — cluster 节点地址表
--
-- __nowaiting = true 很关键：节点名未解析时 cluster.call 立即报错
-- （"cluster node [x] is absent."），而不是在 clusterd 内部永久阻塞。
-- 跳转回滚用例正是靠这个"立即失败"来触发回滚。

__nowaiting = true

node_a = "127.0.0.1:2541"
node_b = "127.0.0.1:2542"
