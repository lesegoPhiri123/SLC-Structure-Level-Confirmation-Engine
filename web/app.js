const POLL_MS = 3000;

const chartEl = document.getElementById('chart');
chartEl.style.position = 'relative';

const chart = LightweightCharts.createChart(chartEl, {
  layout: { background: { color: 'transparent' }, textColor: '#e6e9ef' },
  grid: {
    vertLines: { color: '#1b2130' },
    horzLines: { color: '#1b2130' },
  },
  timeScale: { timeVisible: true, secondsVisible: false, borderColor: '#232838' },
  rightPriceScale: { borderColor: '#232838' },
  crosshair: { mode: LightweightCharts.CrosshairMode.Normal },
});

const candleSeries = chart.addCandlestickSeries({
  upColor: '#2ecf6d',
  downColor: '#ef5350',
  borderVisible: false,
  wickUpColor: '#2ecf6d',
  wickDownColor: '#ef5350',
});

const overlay = document.createElement('div');
overlay.style.position = 'absolute';
overlay.style.inset = '0';
overlay.style.pointerEvents = 'none';
chartEl.appendChild(overlay);

const zoneDivs = new Map();
let latestState = null;

function resizeChart() {
  chart.resize(chartEl.clientWidth, chartEl.clientHeight);
  renderOverlays();
}
new ResizeObserver(resizeChart).observe(chartEl);

function zoneColor(zone) {
  if (zone.status === 'broken') return '#8892a0';
  if (zone.flipped) return '#e0b64c';
  return zone.type === 'supply' ? '#ef5350' : '#29b6f6';
}

function renderOverlays() {
  if (!latestState) return;
  const seen = new Set();
  const rightX = chartEl.clientWidth;

  for (const zone of latestState.zones) {
    if (zone.status === 'expired' || zone.status === 'traded') continue;

    const x1 = chart.timeScale().timeToCoordinate(zone.time);
    const yHigh = candleSeries.priceToCoordinate(zone.high);
    const yLow = candleSeries.priceToCoordinate(zone.low);
    if (x1 === null || yHigh === null || yLow === null) continue;

    seen.add(zone.id);
    let div = zoneDivs.get(zone.id);
    if (!div) {
      div = document.createElement('div');
      div.className = 'zone-overlay-rect';
      overlay.appendChild(div);
      zoneDivs.set(zone.id, div);
    }
    const color = zoneColor(zone);
    div.style.left = `${x1}px`;
    div.style.top = `${yHigh}px`;
    div.style.width = `${Math.max(0, rightX - x1)}px`;
    div.style.height = `${Math.max(0, yLow - yHigh)}px`;
    div.style.borderColor = color;
    div.style.background = `${color}22`;
    div.style.borderStyle = zone.status === 'broken' ? 'dashed' : 'solid';
  }

  for (const [id, div] of zoneDivs) {
    if (!seen.has(id)) {
      div.remove();
      zoneDivs.delete(id);
    }
  }
}

function fmtTime(unixSeconds) {
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

function renderRegime(state) {
  const badge = document.getElementById('regimeBadge');
  badge.textContent = state.htf_state;
  badge.className = 'badge ' + (
    state.htf_state === 'UPTREND' ? 'badge-up' :
    state.htf_state === 'DOWNTREND' ? 'badge-down' : 'badge-flat'
  );
  document.getElementById('symbolLabel').textContent = `${state.symbol} · HTF ${state.htf} · LTF ${state.ltf}`;
  document.getElementById('updatedLabel').textContent = `updated ${state.updated}`;
}

function renderList(elId, items, emptyText, renderItem) {
  const el = document.getElementById(elId);
  el.innerHTML = '';
  if (!items || items.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = emptyText;
    el.appendChild(li);
    return;
  }
  for (const item of items.slice().reverse()) {
    const li = document.createElement('li');
    li.innerHTML = renderItem(item);
    el.appendChild(li);
  }
}

function renderPanels(state) {
  renderList('zoneList', state.zones.filter(z => z.status === 'active' || z.status === 'broken'),
    'No active zones', z => `
      <span class="tag-${z.type}">${z.type.toUpperCase()}${z.flipped ? ' ↺' : ''}</span>
      <span>${z.low} – ${z.high}</span>
      <span class="tag-status">${z.status} (${z.touches})</span>
    `);

  renderList('signalList', state.signals, 'No signals yet', s => `
      <span class="tag-${s.dir === 'short' ? 'supply' : 'demand'}">${s.dir.toUpperCase()}</span>
      <span>%K ${s.k}</span>
      <span class="tag-status">${fmtTime(s.time)}</span>
    `);

  renderList('tradeList', state.trades, 'No trades yet', t => `
      <span class="tag-${t.dir === 'short' ? 'supply' : 'demand'}">${t.dir.toUpperCase()}</span>
      <span>${t.entry} · ${t.lots} lots</span>
      <span class="tag-status">${fmtTime(t.time)}</span>
    `);
}

function renderMarkers(state) {
  const markers = [];
  for (const s of state.signals) {
    markers.push({
      time: s.time,
      position: s.dir === 'short' ? 'aboveBar' : 'belowBar',
      color: '#e0b64c',
      shape: s.dir === 'short' ? 'arrowDown' : 'arrowUp',
      text: 'confirm',
    });
  }
  for (const t of state.trades) {
    markers.push({
      time: t.time,
      position: t.dir === 'short' ? 'aboveBar' : 'belowBar',
      color: t.dir === 'short' ? '#ef5350' : '#2ecf6d',
      shape: t.dir === 'short' ? 'arrowDown' : 'arrowUp',
      text: 'entry',
    });
  }
  markers.sort((a, b) => a.time - b.time);
  candleSeries.setMarkers(markers);
}

async function poll() {
  try {
    const res = await fetch('/api/state', { cache: 'no-store' });
    if (!res.ok) throw new Error(`state fetch failed: ${res.status}`);
    const state = await res.json();
    latestState = state;

    candleSeries.setData(state.candles.map(c => ({
      time: c.t, open: c.o, high: c.h, low: c.l, close: c.c,
    })));

    renderRegime(state);
    renderPanels(state);
    renderMarkers(state);
    renderOverlays();
  } catch (err) {
    console.error('SLC poll error:', err);
  } finally {
    setTimeout(poll, POLL_MS);
  }
}

chart.timeScale().subscribeVisibleTimeRangeChange(renderOverlays);
poll();
