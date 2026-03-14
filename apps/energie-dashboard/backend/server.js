const express = require('express');
const Database = require('better-sqlite3');
const cors = require('cors');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const dgram = require('dgram');
const net = require('net');

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
  CREATE TABLE IF NOT EXISTS dagmetingen (
    jaar   INTEGER NOT NULL,
    maand  INTEGER NOT NULL,
    dag    INTEGER NOT NULL,
    e_day  REAL    NOT NULL,
    bron   TEXT    NOT NULL DEFAULT 'lokaal',
    PRIMARY KEY (jaar, maand, dag)
  );
`);

// Migrate existing DB: add columns if missing
try { db.exec(`ALTER TABLE metingen ADD COLUMN laadvergoeding REAL NOT NULL DEFAULT 0`); } catch(e) { /* already exists */ }
try { db.exec(`ALTER TABLE metingen ADD COLUMN teruglevering_vergoeding REAL NOT NULL DEFAULT 0`); } catch(e) { /* already exists */ }

// ─── Live inverter cache ─────────────────────────────────────────────────────
// Voorkomt dat elke page-refresh een UDP-query afvuurt; max 1x per 30 sec.
let liveCache = null;
let liveCacheTs = 0;
const LIVE_CACHE_TTL = 30_000; // ms

async function getLiveData() {
  const ip = getSetting('goodwe_inverter_ip');
  if (!ip) return null;
  const now = Date.now();
  if (liveCache && (now - liveCacheTs) < LIVE_CACHE_TTL) return liveCache;
  try {
    const data = await testLocalInverter(ip);
    if (data.reachable && data.e_day != null) {
      liveCache  = data;
      liveCacheTs = now;
    }
    return data;
  } catch(e) { return { reachable: false, error: e.message }; }
}

// ─── Dagelijkse auto-sync (cron) ─────────────────────────────────────────────
// Elke dag om 22:00 lokale tijd: sla e_day op uit de lokale omvormer.
// Wordt ook direct na opstarten uitgevoerd als vandaag nog geen record is.

function saveDailyEday(eDay) {
  const now = new Date();
  const [yr, mo, dy] = [now.getFullYear(), now.getMonth() + 1, now.getDate()];
  db.prepare(`INSERT INTO dagmetingen (jaar, maand, dag, e_day, bron)
    VALUES (?, ?, ?, ?, 'lokaal')
    ON CONFLICT(jaar, maand, dag) DO UPDATE SET e_day=excluded.e_day, bron='lokaal'
  `).run(yr, mo, dy, eDay);
  console.log(`Dagmeting opgeslagen: ${dy}-${mo}-${yr} = ${eDay} kWh`);
}

async function dailySync() {
  const ip = getSetting('goodwe_inverter_ip');
  if (!ip) return;
  try {
    const data = await testLocalInverter(ip);
    if (data.reachable && data.e_day != null && data.e_day > 0) {
      saveDailyEday(data.e_day);
      // Invalideer live cache zodat dashboard direct verse data krijgt
      liveCache = null;
    }
  } catch(e) { console.error('Dagelijkse sync fout:', e.message); }
}

function scheduleDailySync() {
  const now = new Date();
  const next22 = new Date(now);
  next22.setHours(22, 0, 0, 0);
  if (next22 <= now) next22.setDate(next22.getDate() + 1);
  const msUntil = next22 - now;
  console.log(`Volgende dagelijkse sync om 22:00 (over ${Math.round(msUntil/60000)} min)`);
  setTimeout(() => {
    dailySync();
    setInterval(dailySync, 24 * 60 * 60 * 1000);
  }, msUntil);
}

// Direct bij opstarten: als vandaag nog geen dagmeting is, probeer er één op te slaan
async function syncOnStartup() {
  const ip = getSetting('goodwe_inverter_ip');
  if (!ip) return;
  const now = new Date();
  const [yr, mo, dy] = [now.getFullYear(), now.getMonth() + 1, now.getDate()];
  const existing = db.prepare('SELECT e_day FROM dagmetingen WHERE jaar=? AND maand=? AND dag=?').get(yr, mo, dy);
  if (!existing) {
    console.log('Geen dagmeting voor vandaag gevonden, poging om lokaal uit te lezen...');
    await dailySync();
  }
}
setTimeout(syncOnStartup, 5000); // 5s na opstarten
scheduleDailySync();

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

// ─── GoodWe SEMSPlus sync ────────────────────────────────────────────────────
// Based on HAR analysis of semsplus.goodwe.com traffic:
// - Login endpoint: semsplus.goodwe.com/web/sems/sems-user/api/v1/auth/cross-login
// - Token header uses client "semsPlusWeb", version ""
// - Password sent as plain text (NOT MD5)
// - Extra body fields: agreement:1, isLocal:false, isChinese:false
// - x-signature header: base64(sha256_of_body@timestamp) — exact hash derivation
//   is obfuscated in minified JS; we try with and without it
// - After login, the api base URL is returned in the response (eu-gateway.semsportal.com)

function makeTokenHeader(uid = '', timestamp = 0, token = '', api = '', region = '') {
  return JSON.stringify({
    uid, timestamp, token,
    client: 'semsPlusWeb',
    version: '',
    language: 'nl',
    ...(api ? { api } : {}),
    ...(region ? { region } : {}),
  });
}

function makeSignature(bodyStr) {
  const ts = Date.now();
  const hash = crypto.createHash('sha256').update(bodyStr).digest('hex');
  return Buffer.from(`${hash}@${ts}`).toString('base64');
}

async function httpsPostSems(url, tokenHeaderValue, body) {
  const bodyStr = JSON.stringify(body);
  return httpsPost(url,
    {
      'token': tokenHeaderValue,
      'currentlang': 'nl',
      'neutral': '0',
      'x-signature': makeSignature(bodyStr),
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
      'Origin': 'https://semsplus.goodwe.com',
      'Referer': 'https://semsplus.goodwe.com/',
    },
    body
  );
}

async function goodweLogin(email, password) {
  const errors = [];
  const md5pwd = crypto.createHash('md5').update(password).digest('hex');

  // 1. eu.semsportal.com v2 CrossLogin — primair, geen x-signature, plain wachtwoord
  // Werkt ook na sluiting semsportal.com (30 mei 2026).
  // Token header als base64-encoded JSON. API base zit in res.api (toplevel, niet in data).
  const tokenHdrV2 = Buffer.from(JSON.stringify({
    uid: '', timestamp: 0, token: '', client: 'web', version: '', language: 'en'
  })).toString('base64');

  for (const host of ['eu.semsportal.com', 'www.semsportal.com']) {
    try {
      const res = await httpsPost(`https://${host}/api/v2/common/crosslogin`,
        { Token: tokenHdrV2 },
        { account: email, pwd: password, agreement_agreement: 0, is_local: false }
      );
      if ((res.code === 0 || res.hasError === false) && res.data && res.data.token) {
        console.log(`GoodWe: ingelogd via ${host} v2`);
        // API base: res.api is toplevel "https://eu.semsportal.com/api/"
        // res.components.api is the internal microservice URL — gebruik toplevel
        const apiBase = (res.api || `https://${host}/api/`).replace(/\/$/, '');
        return {
          token: res.data.token,
          uid: res.data.uid,
          timestamp: res.data.timestamp,
          api: apiBase,
          portal: 'sems_v2',
        };
      }
      errors.push(`${host} v2: code=${res.code} msg=${res.msg || ''}`);
    } catch(e) { errors.push(`${host} v2: ${e.message}`); }
  }

  // 2. Classic semsportal.com v1 — bewezen werkend tot 30 mei 2026
  const tokenHeaderClassic = JSON.stringify({ version: 'v2.1.0', client: 'ios', language: 'en' });
  for (const pwd of [md5pwd, password]) {
    try {
      const res = await httpsPost('https://www.semsportal.com/api/v1/Common/CrossLogin',
        { Token: tokenHeaderClassic },
        { account: email, pwd }
      );
      if (res.data && res.data.token) {
        console.log(`GoodWe: ingelogd via semsportal.com v1 (${pwd === md5pwd ? 'MD5' : 'plain'})`);
        return {
          token: res.data.token,
          uid: res.data.uid,
          timestamp: res.data.timestamp,
          api: (res.data.api || 'https://www.semsportal.com').replace(/\/$/, ''),
          portal: 'sems_classic',
        };
      }
      errors.push(`semsportal.com v1 (${pwd === md5pwd ? 'MD5' : 'plain'}): ${res.msg || 'geen token'}`);
    } catch(e) { errors.push(`semsportal.com v1: ${e.message}`); }
  }

  // 3. Nieuw SEMSPlus portaal (HAR-analyse, x-signature — kan c0602 geven)
  try {
    const tokenHeader = makeTokenHeader();
    const body = { account: email, pwd: password, agreement: 1, isLocal: false, isChinese: false };
    const res = await httpsPostSems(
      'https://semsplus.goodwe.com/web/sems/sems-user/api/v1/auth/cross-login',
      tokenHeader,
      body
    );
    if (res.code === '00000' && res.data && res.data.token) {
      console.log('GoodWe: ingelogd via SEMSPlus (nieuw)');
      return {
        token: res.data.token,
        uid: res.data.uid,
        timestamp: res.data.timestamp,
        api: (res.data.api || 'https://eu-gateway.semsportal.com/web/sems').replace(/\/$/, ''),
        region: res.data.region || 'eu',
        portal: 'semsplus_new',
      };
    }
    errors.push(`SEMSPlus nieuw: code=${res.code} desc=${res.description || ''}`);
  } catch(e) {
    errors.push(`SEMSPlus nieuw: ${e.message}`);
  }

  // 4. Oud SEMSPlus portaal fallback (MD5 + plain)
  const tokenHeaderOld = JSON.stringify({ version: 'v2.1.0', client: 'web', language: 'en' });
  for (const pwd of [md5pwd, password]) {
    try {
      const res = await httpsPost('https://semsplus.goodwe.com/api/v1/Common/CrossLogin',
        { Token: tokenHeaderOld },
        { account: email, pwd }
      );
      if (res.data && res.data.token) {
        console.log(`GoodWe: ingelogd via SEMSPlus oud (${pwd === md5pwd ? 'MD5' : 'plain'})`);
        return {
          token: res.data.token,
          uid: res.data.uid,
          timestamp: res.data.timestamp,
          api: (res.data.api || 'https://semsplus.goodwe.com').replace(/\/$/, ''),
          portal: 'semsplus_old',
        };
      }
    } catch(e) { errors.push(`SEMSPlus oud (${pwd === md5pwd ? 'MD5' : 'plain'}): ${e.message}`); }
  }

  throw new Error('GoodWe login mislukt op alle portals. ' + errors.join(' | '));
}

async function fetchGoodweMonthly(auth, stationId) {
  const monthly = {};
  const currentYear = new Date().getFullYear();
  const api = auth.api;

  // New SEMSPlus API: sems-plant/api/stations/production per year/month
  // We fetch month-by-month for each year to get opgewekt (generation)
  // Note: GoodWe levert ALLEEN opgewekt. Teruggeleverd komt van Tibber.
  if (auth.portal === 'semsplus_new') {
    const tokenHeader = makeTokenHeader(auth.uid, auth.timestamp, auth.token, auth.api, auth.region);
    for (let yr = currentYear - 2; yr <= currentYear; yr++) {
      for (let mo = 1; mo <= 12; mo++) {
        if (yr === currentYear && mo > new Date().getMonth() + 1) break;
        const startTime = `${yr}-${String(mo).padStart(2,'0')}-01 00:00:00`;
        const endDay = new Date(yr, mo, 0).getDate();
        const endTime = `${yr}-${String(mo).padStart(2,'0')}-${endDay} 23:59:59`;
        try {
          const body = {
            stationId,
            items: ['profitProStats', 'proSystemTotalStats'],
            dimension: 'month',
            isReport: false,
            startTime,
            endTime,
          };
          const res = await httpsPostSems(`${api}/sems-plant/api/stations/production`, tokenHeader, body);
          if (res.code === '00000' && res.data) {
            if (!monthly[yr]) monthly[yr] = {};
            if (!monthly[yr][mo]) monthly[yr][mo] = {};
            // proSystemTotalStats contains total generation
            const genStat = res.data.proSystemTotalStats;
            if (genStat && genStat.eTotal !== undefined) monthly[yr][mo].opgewekt = genStat.eTotal;
            else if (genStat && genStat.eMonth !== undefined) monthly[yr][mo].opgewekt = genStat.eMonth;
          }
        } catch(e) { /* skip */ }
      }
    }

    // If no data from production endpoint, try statisticsAndPreV2 for generation
    const hasData = Object.values(monthly).some(yrData => Object.values(yrData).some(v => v.opgewekt > 0));
    if (!hasData) {
      for (let yr = currentYear - 2; yr <= currentYear; yr++) {
        try {
          const body = {
            stationId,
            items: ['pSystem'],
            timeScale: 3, // 3 = monthly
            timeZone: -1,
            startTime: `${yr}-01-01 00:00:00`,
            endTime: `${yr}-12-31 23:59:59`,
          };
          const tokenHeader = makeTokenHeader(auth.uid, auth.timestamp, auth.token, auth.api, auth.region);
          const res = await httpsPostSems(`${api}/sems-plant/api/v1/hems/power/statisticsAndPreV2`, tokenHeader, body);
          if (res.code === '00000' && res.data && res.data.pSystem) {
            res.data.pSystem.forEach((pt, i) => {
              const mo = i + 1;
              if (!monthly[yr]) monthly[yr] = {};
              if (!monthly[yr][mo]) monthly[yr][mo] = {};
              if (!monthly[yr][mo].opgewekt && pt.value !== undefined) monthly[yr][mo].opgewekt = pt.value;
            });
          }
        } catch(e) { /* skip */ }
      }
    }
    return monthly;
  }

  // Legacy portals: old Token-header format (sems_classic, sems_v2, semsplus_old)
  let apiBase = auth.api;
  // sems_v2 returns api as "https://eu.semsportal.com/api/" — strip trailing slash for consistency
  if (apiBase && apiBase.endsWith('/')) apiBase = apiBase.slice(0, -1);

  // Build token header for legacy portals (sems_classic, sems_v2, semsplus_old)
  const tokenHeader = JSON.stringify({
    version: auth.portal === 'sems_v2' ? '' : 'v2.1.0',
    client: auth.portal === 'semsplus_old' ? 'web' : (auth.portal === 'sems_v2' ? 'web' : 'ios'),
    language: 'en',
    token: auth.token,
    uid: auth.uid,
    timestamp: auth.timestamp,
  });

  for (let yr = currentYear - 2; yr <= currentYear; yr++) {
    // Primary: GetPowerStationByMonth
    try {
      const res = await httpsPost(`${apiBase}/v2/PowerStation/GetPowerStationByMonth`,
        { Token: tokenHeader },
        { powerStationId: stationId, count: '12', date: `${yr}-01-01` }
      );
      if (res.data && res.data.month) {
        res.data.month.forEach((m_data, i) => {
          const m = i + 1;
          if (!monthly[yr]) monthly[yr] = {};
          if (!monthly[yr][m]) monthly[yr][m] = {};
          if (m_data.eMonth !== undefined && m_data.eMonth !== null) monthly[yr][m].opgewekt = m_data.eMonth;
          // Note: teruggeleverd (eSell) is NOT stored here - Tibber provides it
        });
      }
    } catch(e) { /* skip */ }

    // Fallback: GetChartByPlant
    const hasData = monthly[yr] && Object.values(monthly[yr]).some(v => v.opgewekt > 0);
    if (!hasData) {
      try {
        const res = await httpsPost(`${apiBase}/v2/Charts/GetChartByPlant`,
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
  return { monthly: await fetchGoodweMonthly(auth, stationId), portal: auth.portal };
}

// ─── GoodWe lokale omvormer (UDP poort 8899) ────────────────────────────────
// Protocol: Modbus RTU over UDP, AA55-wrapped response.
// Gebaseerd op analyse van echte HA debug logs + goodwe python library.
//
// Query: Modbus RTU  [unit_id=0x7F][FC03][start=30100][count=73][CRC16]
//   = 7f 03 75 94 00 49 d5 c2
//
// Response: AA55-wrapped  AA 55 [unit_id=7F] [FC=03] [byte_count=0x92] [data 146 bytes] [chk]
//
// Registermap (relatief, reg 0 = adres 30100):
//   reg[18]    Vgrid L1    × 0.1  V
//   reg[19]    Vgrid L2    × 0.1  V
//   reg[20]    Vgrid L3    × 0.1  V
//   reg[24]    Fgrid       × 0.01 Hz
//   reg[39]    p_pv        W      (huidig PV vermogen)
//   reg[41]    temp        × 0.1  °C
//   reg[44]    e_day       × 0.1  kWh
//   reg[46]    p_grid      W      (int16, negatief = teruglevering aan net)
//   reg[47+48] e_total     × 0.1  kWh  (uint32)

function modbusRtu(data) {
  // Modbus CRC16: poly 0xA001, init 0xFFFF
  let crc = 0xFFFF;
  for (const b of data) {
    crc ^= b;
    for (let i = 0; i < 8; i++) crc = (crc & 1) ? (crc >>> 1) ^ 0xA001 : crc >>> 1;
  }
  return crc;
}

function buildModbusQuery(unitId, startReg, count) {
  const frame = Buffer.from([
    unitId, 0x03,
    startReg >> 8, startReg & 0xFF,
    count >> 8, count & 0xFF,
  ]);
  const crc = modbusRtu(frame);
  return Buffer.concat([frame, Buffer.from([crc & 0xFF, crc >> 8])]);
}

function buildAA55Query(srcAddr, dstAddr, cmd) {
  const pkt = Buffer.from([0xAA, 0x55, srcAddr, dstAddr, 0x01, cmd, 0x00]);
  let chk = 0;
  for (const b of pkt) chk += b;
  chk &= 0xFFFF;
  return Buffer.concat([pkt, Buffer.from([chk >> 8, chk & 0xFF])]);
}

function udpRequest(host, port, queryBuf, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const sock = dgram.createSocket('udp4');
    const timer = setTimeout(() => {
      sock.close();
      reject(new Error(`Timeout na ${timeoutMs}ms`));
    }, timeoutMs);
    sock.on('message', msg => { clearTimeout(timer); sock.close(); resolve(msg); });
    sock.on('error', err => { clearTimeout(timer); try { sock.close(); } catch(e) {} reject(err); });
    sock.send(queryBuf, 0, queryBuf.length, port, host,
      err => { if (err) { clearTimeout(timer); reject(err); } });
  });
}

function parseAA55ModbusResponse(buf) {
  // AA55-wrapped Modbus response:
  // AA 55 [unit_id] [fc=03] [byte_count] [data...] [chk_hi] [chk_lo]
  if (!buf || buf.length < 7) return null;
  if (buf[0] !== 0xAA || buf[1] !== 0x55) return null;
  if (buf[3] !== 0x03) return null;   // fc moet 03 zijn

  const byteCount = buf[4];
  if (buf.length < 5 + byteCount + 2) return null;  // afgekapt

  const data = buf.slice(5, 5 + byteCount);   // 146 bytes voor count=73

  const r16u = (reg) => {
    const off = reg * 2;
    return (off + 1 < data.length) ? data.readUInt16BE(off) : null;
  };
  const r16s = (reg) => {
    const off = reg * 2;
    return (off + 1 < data.length) ? data.readInt16BE(off) : null;
  };
  const r32u = (reg) => {
    const off = reg * 2;
    return (off + 3 < data.length) ? data.readUInt32BE(off) : null;
  };

  const v = r16u(18);
  const f = r16u(24);
  const p = r16u(39);
  const t = r16u(41);
  const ed = r16u(44);
  const pg = r16s(46);
  const et = r32u(47);

  return {
    familie:      'ET/ES 3-fase',
    data_bytes:   byteCount,
    raw_hex:      buf.toString('hex'),
    v_grid:       v  != null ? v / 10   : null,   // V
    f_grid:       f  != null ? f / 100  : null,   // Hz
    p_pv:         p,                               // W huidig PV vermogen
    temp:         t  != null ? t / 10   : null,   // °C
    e_day:        ed != null ? ed / 10  : null,   // kWh vandaag
    p_grid:       pg,                              // W (negatief = teruglevering)
    e_total:      et != null ? et / 10  : null,   // kWh cumulatief
  };
}

async function testLocalInverter(host, port = 8899) {
  // Stap 1: AA55 discovery
  let model = null;
  try {
    const resp = await udpRequest(host, port, buildAA55Query(0xC0, 0x7F, 0x02), 3000);
    if (resp && resp.length > 8 && resp[0] === 0xAA && resp[1] === 0x55) {
      const modelBytes = resp.slice(6, resp.length - 2);
      const modelStr = modelBytes.toString('latin1').replace(/[\x00-\x1f]/g, '').trim();
      if (modelStr.length > 2) model = modelStr;
    }
  } catch(e) {
    return { reachable: false, error: e.message };
  }

  // Stap 2: Modbus RTU query — 7f 03 75 94 00 49 d5 c2
  const modbusQuery = buildModbusQuery(0x7F, 30100, 73);
  try {
    const resp   = await udpRequest(host, port, modbusQuery, 5000);
    const parsed = parseAA55ModbusResponse(resp);
    if (parsed && parsed.e_day != null) {
      return { reachable: true, model, ...parsed };
    }
    // Fallback: ruwe response tonen als parse mislukt
    return {
      reachable: true, model,
      raw_hex: resp ? resp.toString('hex') : null,
      error: parsed ? 'Parsering gaf geen e_day' : 'Onverwacht responsformaat',
    };
  } catch(e) {
    return { reachable: true, model, error: `Modbus query mislukt: ${e.message}` };
  }
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
  const keys = ['tibber_token', 'goodwe_email', 'goodwe_station_id', 'goodwe_inverter_ip'];
  const result = {};
  for (const k of keys) result[k] = getSetting(k) || '';
  // Never send password back
  result.goodwe_has_password = !!getSetting('goodwe_password');
  res.json(result);
});

app.post('/api/instellingen', (req, res) => {
  const { tibber_token, goodwe_email, goodwe_password, goodwe_station_id, goodwe_inverter_ip } = req.body;
  if (tibber_token !== undefined) setSetting('tibber_token', tibber_token);
  if (goodwe_email !== undefined) setSetting('goodwe_email', goodwe_email);
  if (goodwe_password !== undefined && goodwe_password !== '') setSetting('goodwe_password', goodwe_password);
  if (goodwe_station_id !== undefined) setSetting('goodwe_station_id', goodwe_station_id);
  if (goodwe_inverter_ip !== undefined) setSetting('goodwe_inverter_ip', goodwe_inverter_ip);
  res.json({ success: true });
});

// Debug endpoint — test lokale omvormer bereikbaarheid
app.get('/api/debug/inverter', async (req, res) => {
  const ip = getSetting('goodwe_inverter_ip');
  if (!ip) return res.status(400).json({ error: 'Geen omvormer IP-adres ingesteld' });
  try {
    const result = await testLocalInverter(ip);
    res.json(result);
  } catch(e) {
    res.status(500).json({ error: e.message });
  }
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
          // GoodWe levert ALLEEN opgewekt. Teruggeleverd komt van Tibber.
          db.prepare(`INSERT INTO metingen (jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(jaar, maand) DO UPDATE SET
              opgewekt=excluded.opgewekt
          `).run(Number(yr), Number(mo),
            existing?.verbruik || 0,
            vals.opgewekt || 0,
            existing?.teruggeleverd || 0,
            existing?.kosten || 0,
            existing?.laadvergoeding || 0,
            existing?.teruglevering_vergoeding || 0
          );
          count++;
        }
      }
      const portalLabel = portal === 'semsplus_new' ? 'SEMSPlus (nieuw)' : portal === 'semsplus_old' ? 'SEMSPlus (oud)' : portal === 'sems_v2' ? 'semsportal.com v2' : 'semsportal.com';
      results.goodwe = `${count} maanden bijgewerkt via ${portalLabel}`;
    } catch(e) {
      results.errors.push('GoodWe cloud: ' + e.message);

      // Fallback: gebruik dagmetingen van lokale omvormer als cloud onbereikbaar is
      const ip = getSetting('goodwe_inverter_ip');
      if (ip) {
        try {
          const currentYear = new Date().getFullYear();
          let fallbackCount = 0;
          for (let yr = currentYear - 2; yr <= currentYear; yr++) {
            for (let mo = 1; mo <= 12; mo++) {
              const dagRows = db.prepare(
                'SELECT e_day FROM dagmetingen WHERE jaar=? AND maand=? ORDER BY dag DESC'
              ).all(yr, mo);
              if (!dagRows.length) continue;

              // Som van alle dagmetingen = maandopbrengst
              // Neem de hoogste e_day van de laatste dag als meest betrouwbaar
              // (dongle reset e_day elke dag; de som is accuraat)
              const maandOpgewekt = dagRows.reduce((s, r) => s + r.e_day, 0);
              if (maandOpgewekt <= 0) continue;

              const existing = db.prepare('SELECT * FROM metingen WHERE jaar=? AND maand=?').get(yr, mo);
              // Alleen bijwerken als er nog geen cloud-waarde is of als het een verbetering is
              if (!existing || existing.opgewekt === 0) {
                db.prepare(`INSERT INTO metingen (jaar, maand, verbruik, opgewekt, teruggeleverd, kosten, laadvergoeding, teruglevering_vergoeding)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT(jaar, maand) DO UPDATE SET opgewekt=excluded.opgewekt
                `).run(yr, mo,
                  existing?.verbruik || 0,
                  maandOpgewekt,
                  existing?.teruggeleverd || 0,
                  existing?.kosten || 0,
                  existing?.laadvergoeding || 0,
                  existing?.teruglevering_vergoeding || 0
                );
                fallbackCount++;
              }
            }
          }
          if (fallbackCount > 0) {
            results.goodwe = `${fallbackCount} maanden bijgewerkt via lokale dagmetingen (cloud onbereikbaar)`;
            // Verwijder de cloud-fout want we hebben een werkend alternatief
            results.errors = results.errors.filter(e => !e.startsWith('GoodWe cloud:'));
          }
        } catch(fe) { results.errors.push('GoodWe fallback: ' + fe.message); }
      }
    }
  }

  res.json(results);
});

// Live inverter data
app.get('/api/live', async (req, res) => {
  const ip = getSetting('goodwe_inverter_ip');
  if (!ip) return res.json({ available: false, reason: 'Geen omvormer IP ingesteld' });
  const data = await getLiveData();
  res.json({ available: true, ...data });
});

// Dagmetingen overzicht
app.get('/api/dagmetingen/:jaar/:maand', (req, res) => {
  const rows = db.prepare(
    'SELECT dag, e_day, bron FROM dagmetingen WHERE jaar=? AND maand=? ORDER BY dag ASC'
  ).all(req.params.jaar, req.params.maand);
  res.json(rows);
});

app.listen(3001, () => console.log('Backend running on port 3001'));
