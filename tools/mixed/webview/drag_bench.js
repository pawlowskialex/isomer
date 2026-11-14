// The 2048 drag benchmark for a JavaScript engine (a web view's, a browser's
// or Node's): the same events and samples as tools/mixed/host's DragBench
// (testBenchmarkDrag's method), run on a self-contained reactor or on a
// runtime module with side modules placed by a dylink loader (node/loader.mjs's,
// without Node's APIs). No Node or DOM dependencies: the caller hands in the
// modules' bytes and a clock.
//
//   import { load, dragBench } from './drag_bench.js'
//   const app = load({ main: bytes, sides: [bytes, …] })
//   const report = dragBench(app, () => performance.now())
//
// `app.step(value)` / `app.render()` are what a native host driving the page
// event by event calls (the host-driven mode in WebViewBench.swift).

// --- A minimal WASI: no files, no preopens, args ["app"], stdout to a log.
function makeWASI(getMemory, log) {
  const ENOSYS = 52, EBADF = 8;
  const dv = () => new DataView(getMemory().buffer);
  const out = { 1: '', 2: '' };
  const wasi = {
    args_sizes_get: (argc, size) => { dv().setUint32(argc, 1, true); dv().setUint32(size, 4, true); return 0; },
    args_get: (argv, buf) => { dv().setUint32(argv, buf, true); new Uint8Array(getMemory().buffer).set([97, 112, 112, 0], buf); return 0; },
    environ_sizes_get: (n, size) => { dv().setUint32(n, 0, true); dv().setUint32(size, 0, true); return 0; },
    environ_get: () => 0,
    clock_res_get: (id, res) => { dv().setBigUint64(res, 1000n, true); return 0; },
    clock_time_get: (id, precision, time) => {
      const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
      dv().setBigUint64(time, ns, true); return 0;
    },
    random_get: (p, n) => { const b = new Uint8Array(getMemory().buffer, p, n); for (let i = 0; i < n; i += 65536) crypto.getRandomValues(b.subarray(i, Math.min(n, i + 65536))); return 0; },
    fd_write: (fd, iovs, n, written) => {
      let total = 0; const d = dv(); const m = new Uint8Array(getMemory().buffer);
      for (let k = 0; k < n; k++) {
        const p = d.getUint32(iovs + 8 * k, true), len = d.getUint32(iovs + 8 * k + 4, true);
        if (fd === 1 || fd === 2) {
          out[fd] += new TextDecoder().decode(m.subarray(p, p + len));
          let nl; while ((nl = out[fd].indexOf('\n')) >= 0) { log(out[fd].slice(0, nl)); out[fd] = out[fd].slice(nl + 1); }
        }
        total += len;
      }
      d.setUint32(written, total, true); return fd <= 2 ? 0 : EBADF;
    },
    fd_fdstat_get: (fd, p) => {
      if (fd > 2) return EBADF;
      const d = dv(); d.setUint8(p, 2); d.setUint16(p + 2, 0, true); d.setBigUint64(p + 8, 0n, true); d.setBigUint64(p + 16, 0n, true); return 0;
    },
    fd_prestat_get: () => EBADF,
    fd_prestat_dir_name: () => EBADF,
    fd_close: () => 0,
    proc_exit: (code) => { throw new Error('proc_exit ' + code); },
  };
  return new Proxy(wasi, { get: (t, k) => t[k] ?? (() => ENOSYS) });
}

// The result type of each function import, so stubs return the right zero.
function importResults(bytes) {
  const b = new Uint8Array(bytes); let i = 8; const types = []; const out = {};
  const uleb = () => { let r = 0, s = 0, x; do { x = b[i++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; };
  const str = () => { const n = uleb(); const v = new TextDecoder().decode(b.subarray(i, i + n)); i += n; return v; };
  const T = { 0x7f: 'i32', 0x7e: 'i64', 0x7d: 'f32', 0x7c: 'f64' };
  while (i < b.length) {
    const id = b[i++]; const size = uleb(); const end = i + size;
    if (id === 1) { for (let n = uleb(), k = 0; k < n; k++) { i++; const np = uleb(); i += np; const nr = uleb(); types.push(nr ? T[b[i]] : null); i += nr; } }
    if (id === 2) { for (let n = uleb(), k = 0; k < n; k++) { const m = str(), nm = str(); const kind = b[i++];
      if (kind === 0) out[m + '.' + nm] = types[uleb()]; else if (kind === 1) { i++; const f = uleb(); uleb(); if (f & 1) uleb(); } else if (kind === 2) { const f = uleb(); uleb(); if (f & 1) uleb(); } else if (kind === 3) { i += 2; } else uleb(); } }
    if (id > 2) break;
    i = end;
  }
  return out;
}

function readLEB(bytes, pos) { let r = 0, s = 0, b; do { b = bytes[pos.i++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; }
function dylinkInfo(mod) {
  const [sec] = WebAssembly.Module.customSections(mod, 'dylink.0');
  const bytes = new Uint8Array(sec); const pos = { i: 0 }; const info = {};
  while (pos.i < bytes.length) {
    const kind = bytes[pos.i++]; const size = readLEB(bytes, pos); const end = pos.i + size;
    if (kind === 1) { info.memSize = readLEB(bytes, pos); info.memAlign = readLEB(bytes, pos); info.tableSize = readLEB(bytes, pos); info.tableAlign = readLEB(bytes, pos); }
    pos.i = end;
  }
  return info;
}

// Places a side module over the main instance (the side modules here come
// from the patched wasm-ld: no LOCREL slots to correct).
function loadSide(main, bytes) {
  const mod = new WebAssembly.Module(bytes);
  const info = dylinkInfo(mod);
  const E = main.exports, table = E.__indirect_function_table;
  const align = 1 << info.memAlign;
  const memoryBase = info.memSize ? E.aligned_alloc(align, info.memSize) : 0;
  new Uint8Array(E.memory.buffer, memoryBase, info.memSize).fill(0);
  const tableBase = table.grow(info.tableSize);
  const funcSlot = new Map();
  const slotFor = (f) => { if (!funcSlot.has(f)) { const i = table.grow(1); table.set(i, f); funcSlot.set(f, i); } return funcSlot.get(f); };
  const i32 = (v, mutable = false) => new WebAssembly.Global({ value: 'i32', mutable }, v);
  const env = { memory: E.memory, __indirect_function_table: table, __memory_base: i32(memoryBase), __table_base: i32(tableBase), __stack_pointer: E.__stack_pointer };
  const gotMem = {}, gotFunc = {}, missing = [];
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module === 'env' && imp.name in env) continue;
    const ex = E[imp.name];
    if (imp.module === 'env' && imp.kind === 'function') { if (typeof ex === 'function') env[imp.name] = ex; else missing.push(imp.name); }
    else if (imp.module === 'GOT.mem') { if (ex instanceof WebAssembly.Global) gotMem[imp.name] = i32(ex.value, true); else missing.push('GOT.mem ' + imp.name); }
    else if (imp.module === 'GOT.func') { if (typeof ex === 'function') gotFunc[imp.name] = i32(slotFor(ex), true); else missing.push('GOT.func ' + imp.name); }
    else if (imp.module === 'env' && imp.kind === 'global' && ex instanceof WebAssembly.Global) env[imp.name] = ex;
    else missing.push(`${imp.module}.${imp.name} (${imp.kind})`);
  }
  if (missing.length) throw new Error('unresolved: ' + missing.slice(0, 20).join(', ') + ` (${missing.length})`);
  const inst = new WebAssembly.Instance(mod, { env, 'GOT.mem': gotMem, 'GOT.func': gotFunc, wasi_snapshot_preview1: {} });
  inst.exports.__wasm_apply_data_relocs?.();
  inst.exports.__wasm_call_ctors?.();
  return inst;
}

// Instantiates the main module (a reactor, or the runtime), then the sides.
// The iso_hot and swift_ffi imports are the WasmKit bench's: render_tree
// collects the frame, schedule_render sets wantsRender, the rest answer zero
// (host_value -1).
// `imports(memory, app)` adds or replaces imports (game.js's swift_ffi job
// queue and its calls into the app).
export function load({ main: mainBytes, sides = [], log = () => {}, imports: extra }) {
  const app = { stream: [], wantsRender: false };
  let main = null, side = null;
  const memory = () => main.exports.memory;
  const results = importResults(mainBytes);
  const mod = new WebAssembly.Module(mainBytes);
  const imports = {
    wasi_snapshot_preview1: makeWASI(memory, log),
    iso_hot: {
      render_tree: (p, n) => { app.stream.push(new Uint8Array(memory().buffer, p, n).slice()); },
      log: (p, n) => log('[guest] ' + new TextDecoder().decode(new Uint8Array(memory().buffer, p, n))),
      epoch_millis: () => Date.now(),
      schedule_render: () => { app.wantsRender = true; },
      platform_command: () => {},
      host_value: () => -1,
    },
    env: { __main_argc_argv: (a, b) => side.exports.__main_argc_argv(a, b) },
  };
  if (extra) for (const [m, fns] of Object.entries(extra(memory, app))) imports[m] = { ...(imports[m] ?? {}), ...fns };
  for (const imp of WebAssembly.Module.imports(mod)) if (imp.kind === 'function' && !imports[imp.module]?.[imp.name]) {
    const r = results[imp.module + '.' + imp.name];
    (imports[imp.module] ??= {})[imp.name] = () => (r === 'i64' ? 0n : r ? 0 : undefined);
  }
  main = new WebAssembly.Instance(mod, imports);
  main.exports._initialize?.();
  for (const s of sides) side = loadSide(main, s);
  const E = main.exports;
  const enc = new TextEncoder();
  app.exports = E;
  app.frameBytes = () => { let n = 0; for (const c of app.stream) n += c.length; const o = new Uint8Array(n); n = 0; for (const c of app.stream) { o.set(c, n); n += c.length; } return o; };
  app.start = (w, h) => { E.iso_hot_start(w, h); E.iso_hot_render(); };
  app.render = () => E.iso_hot_render();
  app.send = (id, value) => {
    const idb = enc.encode(id), vb = enc.encode(value);
    const ip = E.iso_hot_alloc(idb.length), vp = E.iso_hot_alloc(Math.max(vb.length, 1));
    new Uint8Array(E.memory.buffer).set(idb, ip); new Uint8Array(E.memory.buffer).set(vb, vp);
    E.iso_hot_event(ip, idb.length, vp, vb.length);
    E.iso_hot_free(ip); E.iso_hot_free(vp);
  };
  return app;
}

// The first id in the frame ending in `suffix` (DragBench.firstID).
export function firstID(bytes, suffix) {
  const s = new TextEncoder().encode(suffix);
  const ok = (c) => (c >= 48 && c <= 57) || c === 46 || (c >= 97 && c <= 122);
  outer: for (let i = 0; i + s.length <= bytes.length; i++) {
    for (let k = 0; k < s.length; k++) if (bytes[i + k] !== s[k]) continue outer;
    let st = i; while (st > 0 && ok(bytes[st - 1])) st--;
    const id = new TextDecoder().decode(bytes.subarray(st, i + s.length)).replace(/^\.+/, '');
    if (id) return id;
  }
  return null;
}

// The events of the benchmark, in order: for each of ten drags, 60
// `changed` values, then the `ended` one (DragBench.run).
export function dragEvents() {
  const directions = [[2, 0], [-2, 0], [0, 2], [0, -2]]; const drags = [];
  for (let drag = 0; drag < 10; drag++) {
    const [dx, dy] = directions[drag % 4]; const changed = [];
    for (let step = 1; step <= 60; step++) changed.push(`changed:${step * dx},${step * dy}`);
    drags.push({ changed, ended: `ended:${60 * dx},${60 * dy}` });
  }
  return drags;
}

export function summarize(firstMs, samples, releases, releaseFrames) {
  const s = samples.slice().sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return {
    firstMs, count: s.length, mean, median: s[s.length >> 1], p90: s[Math.floor(s.length * 9 / 10)], max: s[s.length - 1],
    releaseMs: releases.reduce((a, b) => a + b, 0) / releases.length, releaseFrames: releaseFrames / releases.length,
    line: `first frame ${firstMs.toFixed(1)} ms; event→frame (${s.length} drag events): mean ${mean.toFixed(2)} ms, median ${s[s.length >> 1].toFixed(2)}, p90 ${s[Math.floor(s.length * 9 / 10)].toFixed(2)}, max ${s[s.length - 1].toFixed(2)}; release ${(releases.reduce((a, b) => a + b, 0) / releases.length).toFixed(1)} ms mean (${(releaseFrames / releases.length).toFixed(1)} frames)`,
  };
}

// The whole benchmark inside the engine: what the engine costs, with no
// host crossing per event. `now()` in milliseconds.
export function dragBench(app, now) {
  const t0 = now();
  app.start(390, 680);
  const firstMs = now() - t0;
  const dragID = firstID(app.frameBytes(), '.drag');
  if (!dragID) throw new Error('no drag id');
  const samples = [], releases = []; let releaseFrames = 0;
  for (const { changed, ended } of dragEvents()) {
    for (const v of changed) {
      app.stream.length = 0;
      const t = now();
      app.send(dragID, v); app.render();
      samples.push(now() - t);
    }
    const t = now();
    app.wantsRender = false;
    app.send(dragID, ended);
    let frames = 0;
    do { app.render(); frames++; const w = app.wantsRender; app.wantsRender = false; if (!w) break; } while (frames < 40);
    releases.push(now() - t);
    releaseFrames += frames;
  }
  return summarize(firstMs, samples, releases, releaseFrames);
}
