'use strict';

const rows = document.getElementById('rows');
const statusEl = document.getElementById('status');
const callEl = document.getElementById('call');
const countEl = document.getElementById('count');
const countersEl = document.getElementById('counters');
const human = document.getElementById('human');
const rbn = document.getElementById('rbn');
let displayed = 0;

function applyFilters() {
  for (const tr of rows.children) {
    const feed = tr.dataset.feed;
    tr.hidden = (feed === 'human' && !human.checked) ||
                (feed === 'rbn' && !rbn.checked);
  }
}

function cell(text, className = '') {
  const td = document.createElement('td');
  td.textContent = text ?? '';
  if (className) td.className = className;
  return td;
}

/*
 * CC11 is kept untouched by app.pl.
 * For the presentation only, use the fields already visible in the
 * received CC11 record:
 *
 *   0  CC11
 *   1  frequency
 *   2  DX
 *   3  date
 *   4  UTC time
 *   5  comment
 *   6  spotter
 *
 * No meaning is assigned here to later fields.
 */
function parseCC11(payload) {
  if (typeof payload !== 'string') return null;

  const f = payload.split('^');
  if (f[0] !== 'CC11' || f.length < 7) return null;

  const date = (f[3] || '').trim();
  const time = (f[4] || '').trim().replace(/Z$/i, '');

  return {
    utc: [date, time].filter(Boolean).join(' '),
    freq: (f[1] || '').trim(),
    dx: (f[2] || '').trim(),
    comment: (f[5] || '').trim(),
    spotter: (f[6] || '').trim()
  };
}

human.addEventListener('change', applyFilters);
rbn.addEventListener('change', applyFilters);

document.getElementById('clear').addEventListener('click', () => {
  rows.replaceChildren();
  displayed = 0;
  countEl.textContent = '0 displayed';
});

const proto = location.protocol === 'https:' ? 'wss' : 'ws';
const ws = new WebSocket(`${proto}://${location.host}/ws`);

ws.onmessage = ev => {
  const msg = JSON.parse(ev.data);

  if (msg.type === 'status') {
    statusEl.textContent = msg.state;
    statusEl.dataset.state = msg.state;
    callEl.textContent = `Channel: ${msg.web_call || '—'}`;

    if (msg.counters) {
      countersEl.textContent =
        `HUMAN: ${msg.counters.human || 0} · RBN: ${msg.counters.rbn || 0}`;
    }
    return;
  }

  if (msg.type !== 'feed') return;

  if (msg.counters) {
    countersEl.textContent =
      `HUMAN: ${msg.counters.human || 0} · RBN: ${msg.counters.rbn || 0}`;
  }

  const parsed = parseCC11(msg.payload);
  if (!parsed) return;

  const tr = document.createElement('tr');
  tr.dataset.feed = msg.feed;

  const feedLabel = msg.feed === 'rbn' ? 'RBN' : 'HUM';
  tr.append(
    cell(feedLabel, `feed feed-${msg.feed}`),
    cell(parsed.utc, 'utc'),
    cell(parsed.freq, 'freq'),
    cell(parsed.dx, 'dx'),
    cell(parsed.comment, 'comment'),
    cell(parsed.spotter, 'spotter')
  );

  rows.prepend(tr);

  while (rows.children.length > 500) {
    rows.lastElementChild.remove();
  }

  displayed++;
  countEl.textContent = `${displayed} displayed`;
  applyFilters();
};

ws.onclose = () => {
  statusEl.textContent = 'browser disconnected';
  statusEl.dataset.state = 'closed';
};
