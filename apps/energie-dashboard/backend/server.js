const express = require('express');
const Database = require('better-sqlite3');
const cors = require('cors');
const https = require('https');
const http = require('http');
const crypto = require('crypto');

const app = express();
app.use(cors());
app.use(express.json());

const db = new Database('/data/energie.db');

db.exec(`
  CREATE TABLE IF NOT EXISTS metingen (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    jaar INTEGER NOT NULL,
    maand INTEGER NOT NULL,
    verbruik REAL NOT NULL,
    opgewekt REAL NOT NULL,
    teruggeleverd REAL NOT NULL,
    kosten REAL NOT NULL,
    laadvergoeding REAL NOT NULL DEFAULT 0,
    teruglevering_vergoeding REAL NOT NULL DEFAULT 0,
    UNIQUE(jaar, maand)
  );
  CREATE TABLE IF NOT EXISTS instellingen (
    sleutel TEXT PRIMARY KEY,
    waarde TEXT NOT NULL
  );
`);

// Migrate existing DB: add columns if missing
try { db.exec(`ALTER TABLE metingen ADD COLUMN laadvergoeding REAL NOT NULL DEFAULT 0`); } catch(e) { /* already exists */ }
try { db.exec(`ALTER TABLE metingen ADD COLUMN teruglevering_vergoeding REAL NOT NULL DEFAULT 0`); } catch(e) { /* already exists */ }

// ─── helpers ────────────────────────────────────────────────────────────────

function getSetting(key) {
  const row = db.prepare('SELECT waarde FROM instellingen WHERE sleutel = ?').get(key);
  return row ? row.waarde : null;
}
function setSetting(key, val) {
  db.prepare('INSERT INTO instellingen(sleutel,waarde) VALUES(?,?) ON CONFLICT(sleutel) DO UPDATE SET waarde=excluded.waarde').run(key, val);
}

function httpsPost(url, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = JSON.stringify(body);
    const req = https.request({ hostname: u.hostname, path: u.pathname + u.search, method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), ...headers } }, res => {
      let buf = '';
      res.on('data', d => buf += d);
      res.on('end', () => { try { resolve(JSON.parse(buf)); } catch(e) { reject(new Error('Invalid JSON: ' + buf.slice(0,200))); } });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// ─── Tibber sync ─────────────────────────────────────────────────────────────

// Parse "2025-10-01T00:00:00+00:00" → { y: 2025, m: 10 }
// Using substring to avoid timezone shift when calling new Date() in local time
function parseYearMonth(fromStr) {
  // Tibber from-strings are always "YYYY-MM-DDT..." — take the date part directly
  const [y, m] = fromStr.substring(0, 7).split('-').map(Number);
  return { y, m };
}

async function fetchTibber(token) {
  const query = `{
    viewer {
      homes {
        consumption(resolution: MONTHLY, last: 36) {
          nodes { from cost consumption }
        }
        production(resolution: MONTHLY, last: 36) {
          nodes { from profit production }
        }
      }
    }
  }`;
  const result = await httpsPost('https://api.tibber.com/v1-beta/gql',
    { Authorization: `Bearer ${token}` },
    { query }
  );
  if (result.errors) throw new Error(result.errors[0].message);

  const home = result?.data?.viewer?.homes?.[0];
  if (!home) throw new Error('Geen Tibber woning gevonden');

  const monthly = {};

  // Consumption: verbruik + kosten
  for (const node of (home.consumption?.nodes || [])) {
    if (!node.from) continue;
    const { y, m } = parseYearMonth(node.from);
    if (!monthly[y]) monthly[y] = {};
    if (!monthly[y][m]) monthly[y][m] = {};
    monthly[y][m].verbruik = node.consumption || 0;
    monthly[y][m].kosten   = node.cost || 0;
  }

  // Production: teruggeleverd (kWh) + vergoeding (€ = profit)
  for (const node of (home.production?.nodes || [])) {
    if (!node.from) continue;
    const { y, m } = parseYearMonth(node.from);
    if (!monthly[y]) monthly[y] = {};
    if (!monthly[y][m]) monthly[y][m] = {};
    if (node.production != null) monthly[y][m].teruggeleverd = node.production;
    if (node.profit     != null) monthly[y][m].teruglevering_vergoeding = node.profit;
  }

  return monthly;
}

// ─── GoodWe SEMS / SEMSPlus sync ─────────────────────────────────────────────

async function goodweLoginAttempt(host, email, password, clientType) {
  const tokenHeader = JSON.stringify({ version: 'v2.1.0', client: clientType, language: 'en' });
  // Try MD5 first (old SEMS standard), then plain text (SEMSPlus may differ)
  for (const pwd of [crypto.createHash('md5').update(password).digest('hex'), password]) {
    try {
      const res = await httpsPost(`https://${host}/api/v1/Common/CrossLogin`,
        { Token: tokenHeader },
        { account: email, pwd }
      );
      if (res.data && res.data.token) {
        return {
          token: res.data.token,
          uid: res.data.uid,
          timestamp: res.data.timestamp,
          api: res.data.api || `https://${host}`,
          portal: host.includes('semsplus') ? 'semsplus' : 'sems'
        };
      }
    } catch(e) { /* try next */ }
  }
  throw new Error(`Login mislukt op ${host}`);
}

// Try old portal first (proven API), then SEMSPlus
async function goodweLogin(email, password) {
  const attempts = [
    { host: 'www.semsportal.com', client: 'ios' },
    { host: 'semsplus.goodwe.com', client: 'web' },
  ];
  const errors = [];
  for (const { host, client } of attempts) {
    try {
      const auth = await goodweLoginAttempt(host, email, password, client);
      console.log(`GoodWe: ingelogd via ${host}`);
      return auth;
    } catch(e) {
      errors.push(`${host}: ${e.message}`);
    }
  }
  throw new Error('GoodWe login mislukt op alle portals. ' + errors.join(' | '));
}

async function fetchGoodweMonthly(api, tokenHeader, stationId) {
  const monthly = {};
  const currentYear = new Date().getFullYear();

  for (let yr = currentYear - 2; yr <= currentYear; yr++) {
    // Primary: GetPowerStationByMonth (opgewekt + teruggeleverd)
    try {
      const res = await httpsPost(`${api}/api/v2/PowerStation/GetPowerStationByMonth`,
        { Token: tokenHeader },
        { powerStationId: stationId, count: '12', date: `${yr}-01-01` }
      );
      if (res.data && res.data.month) {
        res.data.month.forEach((m_data, i) => {
          const m = i + 1;
          if (!monthly[yr]) monthly[yr] = {};
          if (!monthly[yr][m]) monthly[yr][m] = {};
          if (m_data.eMonth !== undefined && m_data.eMonth !== null) monthly[yr][m].opgewekt = m_data.eMonth;
          if (m_data.eSell !== undefined && m_data.eSell !== null) monthly[yr][m].teruggeleverd = m_data.eSell;
        });
      }
    } catch(e) { /* skip */ }

    // Fallback: GetChartByPlant for opgewekt only when primary gave nothing
    const hasData = monthly[yr] && Object.values(monthly[yr]).some(v => v.opgewekt > 0);
    if (!hasData) {
      try {
        const res = await httpsPost(`${api}/api/v2/Charts/GetChartByPlant`,
          { Token: tokenHeader },
          { plantuid: stationId, count: '12', date: `${yr}-01-01`, chartIndexId: '2', USD: '1' }
        );
        if (res.data && res.data.lines) {
          const line = res.data.lines.find(l => l.key === 'generation' || l.key === 'eMonth') || res.data.lines[0];
          if (line && line.xy) {
            line.xy.forEach((pt, i) => {
              const m = i + 1;
              if (!monthly[yr]) monthly[yr] = {};
              if (!monthly[yr][m]) monthly[yr][m] = {};
              if (!monthly[yr][m].opgewekt) monthly[yr][m].opgewekt = pt.y || 0;
            });
          }
        }
      } catch(e) { /* skip */ }
    }
  }
  return monthly;
}

async function fetchGoodwe(email, password, stationId) {
  const auth = await goodweLogin(email, password);
  const tokenHeader = JSON.stringify({
    version: 'v2.1.0',
    client: auth.portal === 'semsplus' ? 'web' : 'ios',
    language: 'en',
    token: auth.token,
    uid: auth.uid,
    timestamp: auth.timestamp
  });
  return { monthly: await fetchGoodweMonthly(auth.api, tokenHeader, stationId), portal: auth.portal };
}

// ─── API routes ──────────────────────────────────────────────────────────────

app.get('/api/data', (req, res) => {
  const rows = db.prepare('SELECT * FROM metingen ORDER BY jaar DESC, maand ASC').all();
  const byYear = {};
  for (const row of rows) {
    if (!byYear[row.jaar]) byYear[row.jaar] = [];
    byYear[row.jaar].push(row);
  }
  res.json(byYear);
});

app.get('/api/data/:jaar', (req, res) => {
  const rows = db.prepare('SELECT * FROM metingen WHERE jaar = ? ORDER BY maand ASC').all(req.params.jaar);
  res.json(rows);
});

app.post('/api/data', (req, res) => {
  const { jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding } = req.body;
  try {
    db.prepare(`INSERT INTO metingen (jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(jaar, maand) DO UPDATE SET
        verbruik=excluded.verbruik, opgewekt=excluded.opgewekt,
        teruggeleverd=excluded.teruggeleverd, kosten=excluded.kosten,
        laadvergoeding=excluded.laadvergoeding,
        teruglevering_vergoeding=excluded.teruglevering_vergoeding
    `).run(jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding || 0, teruglevering_vergoeding || 0);
    res.json({ success: true });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.delete('/api/data/:jaar/:maand', (req, res) => {
  db.prepare('DELETE FROM metingen WHERE jaar = ? AND maand = ?').run(req.params.jaar, req.params.maand);
  res.json({ success: true });
});

app.get('/api/years', (req, res) => {
  const rows = db.prepare('SELECT DISTINCT jaar FROM metingen ORDER BY jaar DESC').all();
  res.json(rows.map(r => r.jaar));
});

// Settings
app.get('/api/instellingen', (req, res) => {
  const keys = ['tibber_token', 'goodwe_email', 'goodwe_station_id'];
  const result = {};
  for (const k of keys) result[k] = getSetting(k) || '';
  // Never send password back
  result.goodwe_has_password = !!getSetting('goodwe_password');
  res.json(result);
});

app.post('/api/instellingen', (req, res) => {
  const { tibber_token, goodwe_email, goodwe_password, goodwe_station_id } = req.body;
  if (tibber_token !== undefined) setSetting('tibber_token', tibber_token);
  if (goodwe_email !== undefined) setSetting('goodwe_email', goodwe_email);
  if (goodwe_password !== undefined && goodwe_password !== '') setSetting('goodwe_password', goodwe_password);
  if (goodwe_station_id !== undefined) setSetting('goodwe_station_id', goodwe_station_id);
  res.json({ success: true });
});

// Debug endpoint — returns raw Tibber data without saving anything
app.get('/api/debug/tibber', async (req, res) => {
  const token = getSetting('tibber_token');
  if (!token) return res.status(400).json({ error: 'Geen Tibber token ingesteld' });

  try {
    // 1. Raw GraphQL response
    const query = `{
      viewer {
        homes {
          consumption(resolution: MONTHLY, last: 36) {
            nodes { from cost consumption }
          }
          production(resolution: MONTHLY, last: 36) {
            nodes { from profit production }
          }
        }
      }
    }`;
    const raw = await httpsPost('https://api.tibber.com/v1-beta/gql',
      { Authorization: `Bearer ${token}` },
      { query }
    );

    const home = raw?.data?.viewer?.homes?.[0];
    const consumptionNodes = home?.consumption?.nodes || [];
    const productionNodes  = home?.production?.nodes  || [];

    // 2. Parsed result (what the sync would store)
    const parsed = await fetchTibber(token);

    res.json({
      raw_consumption_count: consumptionNodes.length,
      raw_production_count:  productionNodes.length,
      raw_production_nodes:  productionNodes,   // full list — key for diagnosis
      parsed_monthly:        parsed,
      graphql_errors:        raw.errors || null,
    });
  } catch(e) {
    res.status(500).json({ error: e.message, stack: e.stack });
  }
});


app.post('/api/sync', async (req, res) => {
  const results = { tibber: null, goodwe: null, errors: [] };

  // Tibber
  const tibberToken = getSetting('tibber_token');
  if (tibberToken) {
    try {
      const tibberData = await fetchTibber(tibberToken);
      let count = 0;
      for (const [yr, months] of Object.entries(tibberData)) {
        for (const [mo, vals] of Object.entries(months)) {
          const existing = db.prepare('SELECT * FROM metingen WHERE jaar=? AND maand=?').get(Number(yr), Number(mo));
          // Tibber geeft: verbruik, kosten, en optioneel teruggeleverd (production query)
          // Teruggeleverd en vergoeding alleen overschrijven als Tibber ze teruggeeft
          const teruggeleverd = vals.teruggeleverd !== undefined
            ? vals.teruggeleverd
            : (existing?.teruggeleverd || 0);
          const tl_vergoeding = vals.teruglevering_vergoeding !== undefined
            ? vals.teruglevering_vergoeding
            : (existing?.teruglevering_vergoeding || 0);
          db.prepare(`INSERT INTO metingen (jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(jaar, maand) DO UPDATE SET
              verbruik=excluded.verbruik,
              kosten=excluded.kosten,
              teruggeleverd=excluded.teruggeleverd,
              teruglevering_vergoeding=excluded.teruglevering_vergoeding
          `).run(Number(yr), Number(mo),
            vals.verbruik || 0,
            existing?.opgewekt || 0,
            teruggeleverd,
            vals.kosten || 0,
            existing?.laadvergoeding || 0,
            tl_vergoeding
          );
          count++;
        }
      }
      results.tibber = `${count} maanden bijgewerkt`;
    } catch(e) { results.errors.push('Tibber: ' + e.message); }
  }

  // GoodWe
  const gwEmail = getSetting('goodwe_email');
  const gwPwd = getSetting('goodwe_password');
  const gwStation = getSetting('goodwe_station_id');
  if (gwEmail && gwPwd && gwStation) {
    try {
      const { monthly: gwData, portal } = await fetchGoodwe(gwEmail, gwPwd, gwStation);
      let count = 0;
      for (const [yr, months] of Object.entries(gwData)) {
        for (const [mo, vals] of Object.entries(months)) {
          const existing = db.prepare('SELECT * FROM metingen WHERE jaar=? AND maand=?').get(Number(yr), Number(mo));
          db.prepare(`INSERT INTO metingen (jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(jaar, maand) DO UPDATE SET
              opgewekt=excluded.opgewekt,
              teruggeleverd=excluded.teruggeleverd
          `).run(Number(yr), Number(mo),
            existing?.verbruik || 0,
            vals.opgewekt || 0,
            vals.teruggeleverd !== undefined ? vals.teruggeleverd : (existing?.teruggeleverd || 0),
            existing?.kosten || 0,
            existing?.laadvergoeding || 0,
            existing?.teruglevering_vergoeding || 0
          );
          count++;
        }
      }
      const portalLabel = portal === 'semsplus' ? 'SEMSPlus' : 'semsportal.com';
      results.goodwe = `${count} maanden bijgewerkt via ${portalLabel}`;
    } catch(e) { results.errors.push('GoodWe: ' + e.message); }
  }

  res.json(results);
});

app.listen(3001, () => console.log('Backend running on port 3001'));
