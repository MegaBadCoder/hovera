const stage = document.getElementById('stage');
const hud = document.getElementById('hud');
const chartCanvas = document.getElementById('chart');
const chartCtx = chartCanvas.getContext('2d');

const el = (id) => document.getElementById(id);

const state = {
  paused: false,
  mode: 'learner',
  firmware: true,
  temp: 25,
  bTrueBase: 0.1,
  noise: 0.02,
  bEst: 0,
  anchor: 0,
  firmwareOffset: 0,
  shift: 0,
  drift: 0,
  time: 0,
  still: false,
  residualSmooth: 0,
  wasStill: false,
  headYaw: 0,
  headPitch: 0,
  headRate: 0,
  dragging: false,
  lastPointer: null,
};

const slope = -0.012;
const WINDOW_SECONDS = 0.5;
const WINDOW_SAMPLES = 30;
const learnRing = [];
const chartRing = [];
let lastFirmwareStep = 0;

function biasTrue(temperature) {
  return state.bTrueBase + slope * (temperature - 25);
}

function gauss() {
  let u = 0, v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x060a0f);
scene.fog = new THREE.Fog(0x060a0f, 5, 12);

const camera = new THREE.PerspectiveCamera(60, 1, 0.01, 100);
camera.position.set(0, 0, 0);
camera.lookAt(0, 0, -1);

const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
stage.appendChild(renderer.domElement);

scene.add(new THREE.AmbientLight(0xffffff, 0.9));
const key = new THREE.DirectionalLight(0xffffff, 1.2);
key.position.set(1.4, 1.2, 1.0);
scene.add(key);

const grid = new THREE.GridHelper(12, 24, 0x1d4b46, 0x14212b);
grid.position.y = -1.2;
scene.add(grid);

const forwardGeometry = new THREE.BufferGeometry().setFromPoints([
  new THREE.Vector3(0, -1.2, 0),
  new THREE.Vector3(0, -1.2, -2.6),
]);
const forwardLine = new THREE.Line(forwardGeometry, new THREE.LineDashedMaterial({ color: 0x2f6f5f, dashSize: 0.08, gapSize: 0.06 }));
forwardLine.computeLineDistances();
scene.add(forwardLine);

const arrow = new THREE.ArrowHelper(new THREE.Vector3(0, 0, -1), new THREE.Vector3(0, 0.7, 0), 0.7, 0x5eead4, 0.12, 0.07);
scene.add(arrow);

const marker = new THREE.Mesh(
  new THREE.SphereGeometry(0.045, 24, 16),
  new THREE.MeshBasicMaterial({ color: 0xf0b35b })
);
marker.position.set(0, 0, -2.7);
scene.add(marker);

function makeScreenTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 1024;
  canvas.height = 576;
  const ctx = canvas.getContext('2d');
  const g = ctx.createLinearGradient(0, 0, 1024, 576);
  g.addColorStop(0, '#101a26');
  g.addColorStop(1, '#0b121a');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 1024, 576);
  ctx.strokeStyle = 'rgba(94,234,212,0.35)';
  ctx.lineWidth = 6;
  ctx.strokeRect(18, 18, 988, 540);
  ctx.fillStyle = '#5eead4';
  ctx.font = '600 54px -apple-system, BlinkMacSystemFont, sans-serif';
  ctx.fillText('ЭКРАН В МИРЕ', 64, 120);
  ctx.fillStyle = '#8ba0b8';
  ctx.font = '28px -apple-system, BlinkMacSystemFont, sans-serif';
  ctx.fillText('1.5 м от глаз · поворот виден сферой', 64, 176);
  for (let i = 0; i < 6; i++) {
    ctx.fillStyle = i % 2 ? 'rgba(94,234,212,0.10)' : 'rgba(139,160,184,0.07)';
    ctx.fillRect(64, 230 + i * 48, 896 - i * 40, 28);
  }
  ctx.fillStyle = 'rgba(240,179,91,0.9)';
  ctx.font = '24px ui-monospace, Menlo, monospace';
  ctx.fillText('heading error = 0', 64, 540);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

const screenGroup = new THREE.Group();
const screenMesh = new THREE.Mesh(
  new THREE.PlaneGeometry(2.2, 1.24),
  new THREE.MeshBasicMaterial({ map: makeScreenTexture() })
);
screenGroup.add(screenMesh);
screenGroup.position.set(0, 0, -2.7);
const edges = new THREE.LineSegments(
  new THREE.EdgesGeometry(new THREE.PlaneGeometry(2.2, 1.24)),
  new THREE.LineBasicMaterial({ color: 0x5eead4, transparent: true, opacity: 0.6 })
);
screenGroup.add(edges);
scene.add(screenGroup);

function resize() {
  const width = stage.clientWidth;
  const height = Math.max(stage.clientHeight, 420);
  renderer.setSize(width, height, false);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', resize);
resize();

function pushLearnSample(value) {
  learnRing.push(value);
  if (learnRing.length > 120) learnRing.shift();
}

function pushChartSample(sample) {
  chartRing.push(sample);
  if (chartRing.length > 600) chartRing.shift();
}

function updateStill(windowSamples) {
  if (windowSamples.length < WINDOW_SAMPLES) return { still: false, mean: 0 };
  let min = Infinity, max = -Infinity, sum = 0;
  for (const value of windowSamples) {
    min = Math.min(min, value);
    max = Math.max(max, value);
    sum += value;
  }
  return { still: (max - min) < 1.2, mean: sum / windowSamples.length };
}

function simulate(dt) {
  state.time += dt;
  const bTrue = biasTrue(state.temp);

  state.headRate *= Math.exp(-dt / 0.12);
  const headRate = state.headRate;

  if (state.firmware && state.time - lastFirmwareStep > 3 && Math.abs(headRate) < 2) {
    lastFirmwareStep = state.time;
    state.firmwareOffset += (Math.random() < 0.5 ? -1 : 1) * (0.02 + Math.random() * 0.04);
    state.shift = state.firmwareOffset;
  }
  if (!state.firmware) {
    state.shift *= Math.exp(-dt / 0.5);
  }

  const noise = gauss() * state.noise;
  const measured = headRate + bTrue + state.firmwareOffset + noise;

  const residualForLearn = measured - state.shift;
  pushLearnSample(residualForLearn);

  let tableBias = null;
  if (state.mode === 'table') {
    tableBias = state.anchor + slope * (state.temp - 25);
  }

  if (state.mode !== 'off') {
    const { still, mean } = updateStill(learnRing.slice(-WINDOW_SAMPLES));
    state.still = still && Math.abs(headRate) < 2;
    if (state.still) {
      if (state.mode === 'learner') {
        const alpha = 1 - Math.exp(-dt / 3);
        state.bEst += alpha * (mean - state.bEst);
      } else if (state.mode === 'table' && tableBias !== null) {
        state.anchor += (mean - (state.anchor + slope * (state.temp - 25))) * (1 - Math.exp(-dt / 20));
        state.bEst = state.anchor + slope * (state.temp - 25);
      }
    }
  } else {
    state.still = false;
  }

  const applied = state.mode === 'off' ? 0 : state.bEst;
  const residual = bTrue + state.firmwareOffset - state.shift - applied;
  state.drift += residual * dt;
  state.residualSmooth += (residual - state.residualSmooth) * (1 - Math.exp(-dt / 1.5));

  screenGroup.rotation.y = -state.drift * Math.PI / 180;
  camera.rotation.order = 'YXZ';
  camera.rotation.y = state.headYaw * Math.PI / 180;
  camera.rotation.x = state.headPitch * Math.PI / 180;

  const error = bTrue - applied;
  hud.innerHTML = [
    `T = <b>${state.temp.toFixed(1)} °C</b>`,
    `истинный ноль <b>${bTrue.toFixed(3)} °/с</b>`,
    `оценка <b>${applied.toFixed(3)} °/с</b>`,
    `ошибка <b>${error >= 0 ? '+' : ''}${error.toFixed(3)} °/с</b>`,
    `увод <b>${(state.residualSmooth * 60) >= 0 ? '+' : ''}${(state.residualSmooth * 60).toFixed(1)} °/мин</b>`,
    `угол <b>${state.drift >= 0 ? '+' : ''}${state.drift.toFixed(1)}°</b>`,
    `голова <b>${state.headYaw >= 0 ? '+' : ''}${state.headYaw.toFixed(0)}° / ${state.headPitch >= 0 ? '+' : ''}${state.headPitch.toFixed(0)}°</b>`,
    `скорость головы <b>${Math.abs(state.headRate).toFixed(1)} °/с</b>`,
    state.still ? `<span style="color:#5eead4">покой · учится</span>` : `<span style="color:#8ba0b8">движение · не учится</span>`,
    state.firmware ? `<span style="color:#f0b35b">прошивка: ${state.firmwareOffset.toFixed(3)} °/с</span>` : `<span style="color:#8ba0b8">прошивка: выкл</span>`,
  ].join('<br>');

  pushChartSample({ bTrue, applied, drift: state.drift, still: state.still });
}

function drawChart() {
  const ctx = chartCtx;
  const width = chartCanvas.width, height = chartCanvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = '#0d141d';
  ctx.fillRect(0, 0, width, height);
  ctx.strokeStyle = '#1b2735';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, height / 2);
  ctx.lineTo(width, height / 2);
  ctx.stroke();

  const samples = chartRing.slice(-600);
  if (samples.length < 2) return;
  const biasScale = height / 2 / 0.6;
  const driftScale = height / 2 / 60;

  for (let i = 0; i < samples.length; i++) {
    if (!samples[i].still) continue;
    const x = (i / samples.length) * width;
    ctx.fillStyle = 'rgba(94,234,212,0.45)';
    ctx.fillRect(x, height - 5, width / samples.length + 1, 5);
  }

  const line = (key, color, scale) => {
    ctx.beginPath();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    for (let i = 0; i < samples.length; i++) {
      const value = samples[i][key];
      const x = (i / samples.length) * width;
      const y = height / 2 - value * scale;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.stroke();
  };
  line('bTrue', '#f0b35b', biasScale);
  line('applied', '#5eead4', biasScale);
  line('drift', 'rgba(167,139,250,0.9)', driftScale);
}

let last = performance.now();
function loop(now) {
  requestAnimationFrame(loop);
  const dt = Math.min((now - last) / 1000, 0.05);
  last = now;
  if (!state.paused) {
    for (let i = 0; i < 2; i++) simulate(dt / 2);
  }
  drawChart();
  renderer.render(scene, camera);
}
requestAnimationFrame(loop);

function reset() {
  state.bEst = 0;
  state.anchor = biasTrue(25);
  state.firmwareOffset = 0;
  state.shift = 0;
  state.drift = 0;
  state.time = 0;
  state.residualSmooth = 0;
  state.still = false;
  state.wasStill = false;
  lastFirmwareStep = 0;
  learnRing.length = 0;
  chartRing.length = 0;
  if (state.mode === 'table') state.bEst = biasTrue(state.temp);
  if (state.mode === 'learner') state.bEst = 0;
  if (state.mode === 'off') state.bEst = 0;
}

el('bTrue').addEventListener('input', (e) => {
  state.bTrueBase = Number(e.target.value);
  el('bTrueOut').textContent = `${Number(e.target.value).toFixed(2)} °/с`;
});
el('temp').addEventListener('input', (e) => {
  state.temp = Number(e.target.value);
  el('tempOut').textContent = `${state.temp} °C`;
});
el('noise').addEventListener('input', (e) => {
  state.noise = Number(e.target.value);
  el('noiseOut').textContent = `${state.noise.toFixed(3)} °/с`;
});
for (const button of document.querySelectorAll('#modeRow button')) {
  button.addEventListener('click', () => {
    for (const other of document.querySelectorAll('#modeRow button')) other.classList.toggle('on', other === button);
    state.mode = button.dataset.mode;
    state.bEst = state.mode === 'learner' || state.mode === 'off' ? 0 : biasTrue(state.temp);
    learnRing.length = 0;
    chartRing.length = 0;
    state.drift = 0;
    state.residualSmooth = 0;
  });
}
el('firmware').addEventListener('click', (e) => {
  state.firmware = !state.firmware;
  e.currentTarget.classList.toggle('on', state.firmware);
  if (!state.firmware) state.shift = 0;
});
el('pause').addEventListener('click', (e) => {
  state.paused = !state.paused;
  e.currentTarget.classList.toggle('on', state.paused);
  e.currentTarget.textContent = state.paused ? 'Продолжить' : 'Пауза';
});
el('reset').addEventListener('click', reset);
const surface = renderer.domElement;
surface.style.cursor = 'grab';
surface.addEventListener('pointerdown', (event) => {
  state.dragging = true;
  state.lastPointer = { x: event.clientX, y: event.clientY, time: performance.now() };
  try { surface.setPointerCapture(event.pointerId); } catch (error) {}
  surface.style.cursor = 'grabbing';
});
surface.addEventListener('pointermove', (event) => {
  if (!state.dragging || !state.lastPointer) return;
  const now = performance.now();
  const dx = event.clientX - state.lastPointer.x;
  const dy = event.clientY - state.lastPointer.y;
  const dt = Math.max((now - state.lastPointer.time) / 1000, 0.001);
  const yawDelta = -dx * 0.18;
  state.headYaw = Math.max(-70, Math.min(70, state.headYaw + yawDelta));
  state.headPitch = Math.max(-35, Math.min(35, state.headPitch - dy * 0.12));
  state.headRate += (yawDelta / dt - state.headRate) * 0.5;
  state.lastPointer = { x: event.clientX, y: event.clientY, time: now };
});
for (const type of ['pointerup', 'pointercancel', 'pointerleave']) {
  surface.addEventListener(type, () => {
    state.dragging = false;
    state.lastPointer = null;
    surface.style.cursor = 'grab';
  });
}
reset();
