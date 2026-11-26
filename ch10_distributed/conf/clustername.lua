-- conf/clustername.lua — cluster 节点地址表
--
-- 三个节点共用同一份地址表（生产环境由配置中心下发 + cluster.reload 热更新）。
--
-- __nowaiting 是本文件里最重要的一个开关：
--   true  → 节点名未解析时 cluster.call 立即报错（"cluster node [x] is absent."）
--   false → 节点名未解析时 cluster.call 在 clusterd 内部 skynet.wait() 永久阻塞，
--           而且阻塞的是 clusterd 自己的 dispatch 协程 —— 整个进程的跨节点调用
--           会一起被拖死。默认必须为 true。

__nowaiting = true

auth    = "127.0.0.1:2531"
center1 = "127.0.0.1:2532"
center2 = "127.0.0.1:2533"
