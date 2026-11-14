// A feature (a side module over the runtime module) run by the web view's
// engine for a native app that draws it: the guest's whole loop lives here,
// as a web-view engine's would. The app (PlayEngines.swift's WebViewEngine)
// sends events and calls in (window.game, callAsyncJavaScript); frames go
// out as they are made (the `frame` message, base64), whether an event, a
// Swift task or a timer made them. The guest's calls into the app:
//   host_value        synchronous: an XHR to the app's scheme handler;
//   platform_command  a message;
//   log               a message.
// Swift concurrency: swift_ffi's `task_enqueue` queues a job, a drain runs
// them (`swift_ffi_task_run`) and renders; `task_enqueue_after` is a timer.
import { load } from './drag_bench.js';

const post = (name, body) => window.webkit.messageHandlers[name].postMessage(body);
const dec = new TextDecoder(), enc = new TextEncoder();
let app = null, E = null;
const jobs = [];
let drainQueued = false, renderQueued = false;
const stats = { renders: 0, frames: 0, jobs: 0, hostValues: 0, hostValueMs: 0 };

function base64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function flushFrames() {
  if (!app.stream.length) return;
  const bytes = app.frameBytes();
  app.stream.length = 0;
  stats.frames++;
  post('frame', base64(bytes));
}

// As WasmKitRuntime.renderPending: the frame only if the guest has one.
function render() {
  renderQueued = false;
  stats.renders++;
  (E.iso_hot_render_pending ?? E.iso_hot_render)();
  flushFrames();
}

// The app answers at its display's next refresh (DisplayPacer) with
// game.render().
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  post('wantsRender', 1);
}

function drain() {
  drainQueued = false;
  let n = 0;
  while (jobs.length && n++ < 10000) { E.swift_ffi_task_run(jobs.shift()); stats.jobs++; }
  // As SwiftFFIHostRuntime.onJobsDrained → renderPending.
  render();
}

function enqueue(job) {
  jobs.push(job);
  if (!drainQueued) { drainQueued = true; setTimeout(drain, 0); }
}

const imports = (memory) => {
  const bytes = (p, n) => new Uint8Array(memory().buffer, p, n);
  return {
    iso_hot: {
      schedule_render: () => scheduleRender(),
      log: (p, n) => post('log', dec.decode(bytes(p, n))),
      platform_command: (kp, kn, vp, vn) => post('platform', [dec.decode(bytes(kp, kn)), dec.decode(bytes(vp, vn))]),
      host_value: (kp, kn, out, cap) => {
        const t = performance.now();
        const r = new XMLHttpRequest();
        r.open('GET', 'bench://app/hostValue?key=' + encodeURIComponent(dec.decode(bytes(kp, kn))), false);
        r.send();
        stats.hostValues++;
        stats.hostValueMs += performance.now() - t;
        if (r.status !== 200) return -1;
        const answer = enc.encode(r.responseText);
        if (answer.length <= cap) bytes(out, answer.length).set(answer);
        return answer.length;
      },
    },
    swift_ffi: {
      task_enqueue: (job) => enqueue(job),
      task_enqueue_after: (job, ms) => { setTimeout(() => enqueue(job), Math.max(0, ms)); },
    },
  };
};

async function fetchBytes(name) { return new Uint8Array(await (await fetch(name)).arrayBuffer()); }

window.game = {
  // The runtime and the feature, linked and initialized; `wasm-ms` the
  // compile and instantiate time.
  boot: async () => {
    const [runtime, feature] = await Promise.all([fetchBytes('runtime.wasm'), fetchBytes('feature.wasm')]);
    const t = performance.now();
    app = load({ main: runtime, sides: [feature], imports, log: (l) => post('log', l) });
    E = app.exports;
    // swift_ffi's executor, so the guest's Swift tasks reach the job queue
    // above (a real host installs it through a dependency's register export).
    E['$s9IsomerFFI23swiftFFIInstallExecutoryyF'](0, 0); // () -> (), with Swift's context and error registers
    return { loadMs: performance.now() - t, runtimeBytes: runtime.length, featureBytes: feature.length };
  },
  // WasmFeatureRuntime's calls, as they come: an event renders at once
  // (WasmFeatureRuntime.send asks for a frame after each).
  event: (id, value) => { app.send(id, value); render(); },
  configure: (key, value) => {
    const k = enc.encode(key), v = enc.encode(value);
    const kp = E.iso_hot_alloc(k.length), vp = E.iso_hot_alloc(v.length);
    new Uint8Array(E.memory.buffer).set(k, kp); new Uint8Array(E.memory.buffer).set(v, vp);
    E.iso_hot_configure(kp, k.length, vp, v.length);
    E.iso_hot_free(kp); E.iso_hot_free(vp);
  },
  call: (name, args) => { if (E[name]) E[name](...args); flushFrames(); },
  render: () => render(),
  stats: () => ({ ...stats, memoryBytes: E ? E.memory.buffer.byteLength : 0 }),
};
post('ready', 'ready');
