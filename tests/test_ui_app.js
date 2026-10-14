// Automated unit test for ui/modules/apps/SmoothDrivingCoach/app.js
const assert = require('assert');
const fs = require('fs');
const path = require('path');

let registeredDirectiveName = null;
let registeredDirectiveFactory = null;

global.angular = {
  module: function (modName) {
    assert.strictEqual(modName, 'beamng.apps');
    return {
      directive: function (name, arr) {
        registeredDirectiveName = name;
        registeredDirectiveFactory = arr[arr.length - 1];
        return this;
      }
    };
  }
};

const addedStreams = [];
const removedStreams = [];
global.StreamsManager = {
  add: (s) => addedStreams.push(...s),
  remove: (s) => removedStreams.push(...s)
};

const luaCommands = [];
global.bngApi = {
  activeObjectLua: (cmd) => luaCommands.push(cmd)
};

const storage = {};
global.localStorage = {
  getItem: (k) => storage[k] || null,
  setItem: (k, v) => { storage[k] = String(v); }
};

global.TimeSeries = function () {
  this.points = [];
  this.append = (t, v) => this.points.push([t, v]);
};

global.SmoothieChart = function (opts) {
  this.opts = opts;
  this.series = [];
  this.stopped = false;
  this.addTimeSeries = (ts, style) => this.series.push({ ts, style });
  this.streamTo = () => {};
  this.stop = () => { this.stopped = true; };
};

let oscStarted = 0;
global.window = {
  AudioContext: function () {
    this.state = 'running';
    this.currentTime = 0;
    this.destination = {};
    this.createOscillator = () => ({
      type: 'sine',
      frequency: { setValueAtTime: () => {} },
      connect: () => {},
      start: () => { oscStarted++; },
      stop: () => {}
    });
    this.createGain = () => ({
      gain: {
        setValueAtTime: () => {},
        exponentialRampToValueAtTime: () => {}
      },
      connect: () => {}
    });
    this.close = () => {};
  }
};

// Load app.js
require(path.join(__dirname, '..', 'ui', 'modules', 'apps', 'SmoothDrivingCoach', 'app.js'));
assert.strictEqual(registeredDirectiveName, 'smoothDrivingCoach', 'Directive name must match app.json');

const directive = registeredDirectiveFactory();
assert.ok(directive.template.includes('sdc-root'), 'Template must include root container');
assert.ok(directive.template.includes('/ui/modules/apps/SmoothDrivingCoach/app.css'), 'Template must link app.css');

// Create mock scope and element
const listeners = {};
const scope = {
  $on: (evt, fn) => { listeners[evt] = fn; },
  $evalAsync: (fn) => fn()
};

const makeMockCanvas = () => ({
  width: 160,
  height: 160,
  getContext: () => ({
    setTransform: () => {},
    clearRect: () => {},
    beginPath: () => {},
    arc: () => {},
    fill: () => {},
    stroke: () => {},
    moveTo: () => {},
    lineTo: () => {},
    fillText: () => {}
  })
});

const radarCanvas = makeMockCanvas();
const graphCanvas = makeMockCanvas();
const graphWrap = {
  getBoundingClientRect: () => ({ width: 220, height: 74 })
};

const element = [{
  querySelector: (sel) => {
    if (sel === '.sdc-radar-canvas') return radarCanvas;
    if (sel === '.sdc-graph-canvas') return graphCanvas;
    if (sel === '.sdc-graph-wrap') return graphWrap;
    return null;
  }
}];

directive.link(scope, element);

assert.ok(luaCommands.length >= 1, 'Should auto-load smoothDrivingCoach extension on link');
assert.strictEqual(scope.state.score, 100);
assert.strictEqual(scope.scoreColorClass(), 'sdc-zone-green');

// Emit SmoothDrivingCoachData telemetry (Red jolt event)
listeners['SmoothDrivingCoachData']({}, {
  gHoriz: 0.45,
  gLon: -0.42,
  gLat: 0.16,
  jerkTotal: 1.85,
  pitchDeg: 6.4,
  rollDeg: -1.2,
  score: 82.4,
  zone: 'red',
  category: 'EMBREAGEM',
  diagnosis: 'Tranco de embreagem: segure 1s no ponto de contato antes de soltar o pedal',
  diagSeverity: 'red',
  eventSeq: 1
});

assert.strictEqual(scope.state.scoreStr, '82');
assert.strictEqual(scope.state.gStr, '0.45g');
assert.strictEqual(scope.state.jerkStr, '1.9g/s');
assert.strictEqual(scope.state.pitchStr, '+6.4°');
assert.strictEqual(scope.state.rollStr, '-1.2°');
assert.strictEqual(scope.scoreColorClass(), 'sdc-zone-amber');
assert.strictEqual(scope.zoneColorClass(), 'sdc-zone-red');
assert.strictEqual(scope.diagBorderClass(), 'sdc-border-red');
assert.strictEqual(oscStarted, 1, 'Should play alert beep when eventSeq increments on red jolt');

// Test mute toggle
scope.toggleMute({ stopPropagation: () => {} });
assert.strictEqual(scope.muted, true);
listeners['SmoothDrivingCoachData']({}, {
  gHoriz: 0.48,
  jerkTotal: 2.0,
  score: 60,
  zone: 'red',
  category: 'FREIO',
  diagnosis: 'Cabeçada na parada',
  diagSeverity: 'red',
  eventSeq: 2
});
assert.strictEqual(oscStarted, 1, 'Should NOT play beep when muted');
assert.strictEqual(scope.scoreColorClass(), 'sdc-zone-red');

// Test resetScore
scope.resetScore({ stopPropagation: () => {} });
assert.strictEqual(scope.state.score, 100);
assert.strictEqual(scope.state.category, 'OK');

// Test resize & destroy lifecycle
listeners['app:resized']();
listeners['VehicleFocusChanged']();
listeners['VehicleReset']();
listeners['$destroy']();
assert.deepStrictEqual(removedStreams, ['sensors', 'electrics']);

console.log('[PASS] UI App Directive unit tests passed successfully!');
