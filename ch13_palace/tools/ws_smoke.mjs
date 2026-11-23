#!/usr/bin/env node
// tools/ws_smoke.mjs — WebSocket 入口冒烟（零依赖，Node 18+ 内置 WebSocket）
//
// 用法：
//   node tools/ws_smoke.mjs [url] [account] [password]
//   node tools/ws_smoke.mjs ws://127.0.0.1:9814 dev_ws p
//
// 期望链路（与 test/test_ws_gate.lua 的 W1/W2 同构）：
//   HELLO  → ACTION_RES(aid=1, err=200) + SNAPSHOT(kind=4)
//   ACTION → ACTION_RES(err=200) + DELTA(kind=5)
//
// 退出码：0 全通；1 任一断言失败或超时。
//
// 联调前先起服务：make run（或 make test 结束后手动起）

const url = process.argv[2] || "ws://127.0.0.1:9814";
const account = process.argv[3] || "ws_smoke";
const password = process.argv[4] || "p";

const KIND = { HELLO: 1, REQ: 2, RES: 3, SNAPSHOT: 4, DELTA: 5, EVENT: 6, PING: 7 };
const TIMEOUT_MS = 10000;

let pass = 0;
let fail = 0;

function check(cond, msg) {
  if (cond) {
    pass++;
    console.log(`  ok   ${msg}`);
  } else {
    fail++;
    console.log(`  FAIL ${msg}`);
  }
}

function failAndExit(reason) {
  console.error(`\n== WS SMOKE FAILED: ${reason}`);
  process.exit(1);
}

// 按条件等待帧：先入缓冲，条件匹配即取走；不匹配的帧留在缓冲里供后续使用。
function makeReader(ws) {
  const queue = [];
  let pending = null;

  function drain() {
    if (!pending) return;
    const idx = queue.findIndex(pending.predicate);
    if (idx < 0) return;
    const env = queue.splice(idx, 1)[0];
    clearTimeout(pending.timer);
    const resolve = pending.resolve;
    pending = null;
    resolve(env);
  }

  ws.addEventListener("message", (ev) => {
    let env;
    try {
      env = JSON.parse(typeof ev.data === "string" ? ev.data : String(ev.data));
    } catch {
      console.log(`  (skip non-JSON frame: ${String(ev.data).slice(0, 120)})`);
      return;
    }
    queue.push(env);
    drain();
  });

  return function next(predicate, label) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => failAndExit(`timeout waiting for ${label}`), TIMEOUT_MS);
      pending = { predicate: predicate || (() => true), resolve, timer };
      drain();
    });
  };
}

async function main() {
  console.log(`== ws smoke: ${url} (account=${account})`);

  const ws = new WebSocket(url);
  const next = makeReader(ws);

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("websocket open timeout")), TIMEOUT_MS);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(); });
    ws.addEventListener("error", (e) => { clearTimeout(timer); reject(new Error(e.message || "ws error")); });
  }).catch((e) => failAndExit(e.message));

  check(true, "websocket handshake");

  // ===== HELLO =====
  ws.send(JSON.stringify({ kind: KIND.HELLO, seq: 1, wire: 2, params: { account, password } }));

  const ack = await next((e) => e.kind === KIND.RES, "HELLO ack");
  check(ack.err === 200, `HELLO ok (err=${ack.err})`);
  check(ack.aid === 1, `HELLO ack aid=1 (got ${ack.aid})`);
  check(!!(ack.result && ack.result.token), "token issued");
  check(ack.result && ack.result.wire === 2, "wire=2 negotiated");

  const snap = await next((e) => e.kind === KIND.SNAPSHOT, "SNAPSHOT");
  const fidCount = Object.values(snap.partitions || {})
    .reduce((n, part) => n + Object.keys(part).length, 0);
  check(fidCount > 0, `snapshot carries ${fidCount} fids (rev=${snap.rev})`);
  check(snap.partitions && snap.partitions.base !== undefined, "snapshot has base partition");
  check(
    snap.partitions && snap.partitions.base && snap.partitions.base["2"] === account,
    "base fid 2 = account（fid 对象，不是数组）"
  );

  // ===== ACTION_REQ: u.dev.itemAdd (aid=4) =====
  ws.send(JSON.stringify({ kind: KIND.REQ, seq: 2, aid: 4, params: { itemId: 1001, count: 2 } }));

  const res = await next((e) => e.kind === KIND.RES && e.seq === 2, "ACTION_RES");
  check(res.err === 200, `action ok (err=${res.err})`);
  check(res.delta === undefined, "delta 不嵌在 ACTION_RES 里（wire=2）");

  const delta = await next((e) => e.kind === KIND.DELTA, "DELTA");
  check(delta.base_rev === snap.rev, `delta base_rev = snapshot rev (${delta.base_rev})`);
  check(delta.rev > delta.base_rev, `delta rev 前进 (${delta.base_rev} -> ${delta.rev})`);
  const bag = delta.values && delta.values["7"];
  check(!!bag && bag["1001"] === 2, "delta 带 bag(fid 7) item 1001 = 2");

  // ===== PING =====
  ws.send(JSON.stringify({ kind: KIND.PING, seq: 3 }));
  const pong = await next((e) => e.kind === KIND.PING, "PING pong");
  check(pong.params && pong.params.pong === true, "ping answered");

  ws.close();
  console.log(`\n== WS SMOKE: ${pass} PASS, ${fail} FAIL`);
  process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => failAndExit(e && e.stack ? e.stack : String(e)));
