import { useState, useEffect } from "react";
import { AreaChart, Area, BarChart, Bar, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from "recharts";

const API = "/api";
const MAANDEN = ["Jan","Feb","Mrt","Apr","Mei","Jun","Jul","Aug","Sep","Okt","Nov","Dec"];
const MAANDEN_LANG = ["Januari","Februari","Maart","April","Mei","Juni","Juli","Augustus","September","Oktober","November","December"];

const fmt = (v, unit = "kWh") => v !== undefined && v !== null ? `${Number(v).toLocaleString("nl-NL", {minimumFractionDigits: 0, maximumFractionDigits: 1})} ${unit}` : "–";
const fmtEur = (v) => v !== undefined && v !== null ? `€${Number(v).toLocaleString("nl-NL", {minimumFractionDigits: 2, maximumFractionDigits: 2})}` : "–";

const inputStyle = { width: "100%", boxSizing: "border-box", background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 8, padding: "10px 14px", color: "#e8f0fe", fontSize: 13, fontFamily: "inherit", outline: "none" };

export default function App() {
  const [allData, setAllData] = useState({});
  const [years, setYears] = useState([]);
  const [selectedYear, setSelectedYear] = useState(new Date().getFullYear());
  const [compareYear, setCompareYear] = useState(null);
  const [view, setView] = useState("dashboard");
  const [editModal, setEditModal] = useState(null);
  const [form, setForm] = useState({});
  const [saving, setSaving] = useState(false);
  const [notification, setNotification] = useState(null);
  const [settings, setSettings] = useState({ tibber_token: '', goodwe_email: '', goodwe_password: '', goodwe_station_id: '', goodwe_has_password: false });
  const [syncing, setSyncing] = useState(false);
  const [syncResult, setSyncResult] = useState(null);
  const [savingSettings, setSavingSettings] = useState(false);
  const [csvModal, setCsvModal] = useState(false);
  const [csvPreview, setCsvPreview] = useState(null);   // parsed rows before save
  const [csvError, setCsvError] = useState(null);
  const [csvImporting, setCsvImporting] = useState(false);

  useEffect(() => { loadAll(); loadSettings(); }, []);

  async function loadAll() {
    const [dataRes, yearsRes] = await Promise.all([
      fetch(`${API}/data`).then(r => r.json()),
      fetch(`${API}/years`).then(r => r.json())
    ]);
    setAllData(dataRes);
    setYears(yearsRes);
  }

  async function loadSettings() {
    const s = await fetch(`${API}/instellingen`).then(r => r.json());
    setSettings(prev => ({ ...prev, ...s, goodwe_password: '' }));
  }

  function notify(msg, type = "success") {
    setNotification({ msg, type });
    setTimeout(() => setNotification(null), 4000);
  }

  function openEdit(jaar, maand) {
    const existing = (allData[jaar] || []).find(r => r.maand === maand);
    setForm(existing ? { ...existing } : { jaar, maand, verbruik: "", opgewekt: "", teruggeleverd: "", kosten: "", laadvergoeding: "", teruglevering_vergoeding: "" });
    setEditModal({ jaar, maand });
  }

  async function saveForm() {
    setSaving(true);
    try {
      await fetch(`${API}/data`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jaar: Number(form.jaar), maand: Number(form.maand),
          verbruik: Number(form.verbruik), opgewekt: Number(form.opgewekt),
          teruggeleverd: Number(form.teruggeleverd), kosten: Number(form.kosten),
          laadvergoeding: Number(form.laadvergoeding || 0),
          teruglevering_vergoeding: Number(form.teruglevering_vergoeding || 0)
        })
      });
      await loadAll();
      setEditModal(null);
      notify("Opgeslagen!");
    } catch(e) { notify("Fout bij opslaan", "error"); }
    setSaving(false);
  }

  async function deleteEntry(jaar, maand) {
    if (!confirm(`Verwijder ${MAANDEN_LANG[maand-1]} ${jaar}?`)) return;
    await fetch(`${API}/data/${jaar}/${maand}`, { method: "DELETE" });
    await loadAll();
    notify("Verwijderd");
  }

  function parseCsv(text) {
    const lines = text.trim().split(/\r?\n/).filter(l => l.trim());
    if (lines.length < 2) throw new Error("CSV heeft minimaal een headerregel en één dataregel nodig.");

    const REQUIRED = ["jaar","maand","verbruik","opgewekt","teruggeleverd","kosten"];
    const OPTIONAL  = ["laadvergoeding","teruglevering_vergoeding"];

    // Detect separator: semicolon or comma
    const sep = lines[0].includes(";") ? ";" : ",";
    const headers = lines[0].split(sep).map(h => h.trim().toLowerCase().replace(/["\s]/g, ""));

    const missing = REQUIRED.filter(r => !headers.includes(r));
    if (missing.length > 0) throw new Error(`Ontbrekende verplichte kolommen: ${missing.join(", ")}`);

    const rows = [];
    for (let i = 1; i < lines.length; i++) {
      const cols = lines[i].split(sep).map(c => c.trim().replace(/^"|"$/g, ""));
      const row = {};
      headers.forEach((h, idx) => { row[h] = cols[idx] ?? ""; });

      const jaar  = parseInt(row.jaar);
      const maand = parseInt(row.maand);
      if (isNaN(jaar) || isNaN(maand) || maand < 1 || maand > 12)
        throw new Error(`Regel ${i+1}: ongeldig jaar (${row.jaar}) of maand (${row.maand})`);

      const toNum = (k, required = true) => {
        const v = parseFloat(String(row[k] || "0").replace(",", "."));
        if (required && isNaN(v)) throw new Error(`Regel ${i+1}: ongeldige waarde voor '${k}': ${row[k]}`);
        return isNaN(v) ? 0 : v;
      };

      rows.push({
        jaar, maand,
        verbruik:                toNum("verbruik"),
        opgewekt:                toNum("opgewekt"),
        teruggeleverd:           toNum("teruggeleverd"),
        kosten:                  toNum("kosten"),
        laadvergoeding:          toNum("laadvergoeding", false),
        teruglevering_vergoeding:toNum("teruglevering_vergoeding", false),
      });
    }
    return rows;
  }

  function handleCsvFile(file) {
    setCsvError(null);
    setCsvPreview(null);
    if (!file) return;
    const reader = new FileReader();
    reader.onload = e => {
      try {
        const rows = parseCsv(e.target.result);
        setCsvPreview(rows);
      } catch(err) {
        setCsvError(err.message);
      }
    };
    reader.readAsText(file, "UTF-8");
  }

  async function importCsvRows() {
    if (!csvPreview?.length) return;
    setCsvImporting(true);
    try {
      let ok = 0;
      for (const row of csvPreview) {
        await fetch(`${API}/data`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(row)
        });
        ok++;
      }
      await loadAll();
      setCsvModal(false);
      setCsvPreview(null);
      notify(`${ok} rijen geïmporteerd!`);
    } catch(e) {
      setCsvError("Fout bij importeren: " + e.message);
    }
    setCsvImporting(false);
  }

  async function saveSettings() {
    setSavingSettings(true);
    try {
      await fetch(`${API}/instellingen`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(settings)
      });
      await loadSettings();
      notify("Instellingen opgeslagen!");
    } catch(e) { notify("Fout bij opslaan", "error"); }
    setSavingSettings(false);
  }

  async function doSync() {
    setSyncing(true);
    setSyncResult(null);
    try {
      const result = await fetch(`${API}/sync`, { method: "POST" }).then(r => r.json());
      setSyncResult(result);
      await loadAll();
      if (!result.errors || result.errors.length === 0) notify("Synchronisatie voltooid!");
      else if (result.tibber || result.goodwe) notify("Gedeeltelijk gesynchroniseerd", "warn");
      else notify("Synchronisatie mislukt – zie instellingen", "error");
    } catch(e) { notify("Fout bij synchroniseren: " + e.message, "error"); }
    setSyncing(false);
  }

  const yearData = allData[selectedYear] || [];
  const compareData = compareYear ? (allData[compareYear] || []) : [];

  const chartData = MAANDEN.map((m, i) => {
    const e = yearData.find(r => r.maand === i+1);
    const c = compareData.find(r => r.maand === i+1);
    const nettoKosten  = e ? (e.kosten - (e.laadvergoeding || 0) - (e.teruglevering_vergoeding || 0)) : null;
    const nettoKostenC = c ? (c.kosten - (c.laadvergoeding || 0) - (c.teruglevering_vergoeding || 0)) : null;
    return {
      maand: m,
      verbruik: e?.verbruik ?? null,
      opgewekt: e?.opgewekt ?? null,
      teruggeleverd: e?.teruggeleverd ?? null,
      kosten: e?.kosten ?? null,
      laadvergoeding: e?.laadvergoeding ?? null,
      teruglevering_vergoeding: e?.teruglevering_vergoeding ?? null,
      nettoKosten,
      [`verbruik_${compareYear}`]: c?.verbruik ?? null,
      [`opgewekt_${compareYear}`]: c?.opgewekt ?? null,
      [`kosten_${compareYear}`]: c?.kosten ?? null,
      [`nettoKosten_${compareYear}`]: nettoKostenC,
    };
  });

  const totals = yearData.reduce((acc, r) => ({
    verbruik: acc.verbruik + r.verbruik,
    opgewekt: acc.opgewekt + r.opgewekt,
    teruggeleverd: acc.teruggeleverd + r.teruggeleverd,
    kosten: acc.kosten + r.kosten,
    laadvergoeding: acc.laadvergoeding + (r.laadvergoeding || 0),
    teruglevering_vergoeding: acc.teruglevering_vergoeding + (r.teruglevering_vergoeding || 0),
  }), { verbruik: 0, opgewekt: 0, teruggeleverd: 0, kosten: 0, laadvergoeding: 0, teruglevering_vergoeding: 0 });

  const totaleVergoeding  = totals.laadvergoeding + totals.teruglevering_vergoeding;
  const nettoKostenTotaal = totals.kosten - totaleVergoeding;
  const hasLaadvergoeding = yearData.some(r => r.laadvergoeding > 0);

  const allYearsForInput = [];
  for (let y = 2024; y <= new Date().getFullYear() + 1; y++) allYearsForInput.push(y);

  const hasTibber = !!settings.tibber_token;
  const hasGoodwe = !!(settings.goodwe_email && settings.goodwe_station_id && settings.goodwe_has_password);
  const canSync = hasTibber || hasGoodwe;

  return (
    <div style={{ minHeight: "100vh", background: "#0a0f1e", color: "#e8f0fe", fontFamily: "'IBM Plex Mono', monospace" }}>
      <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Space+Grotesk:wght@300;400;600;700&display=swap" rel="stylesheet" />
      <style>{`@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } } input:focus { border-color: rgba(0,212,160,0.5) !important; }`}</style>

      {notification && (
        <div style={{ position: "fixed", top: 20, right: 20, zIndex: 9999, background: notification.type === "error" ? "#ff4444" : notification.type === "warn" ? "#f4a261" : "#00d4a0", color: "#000", padding: "12px 20px", borderRadius: 8, fontWeight: 600, fontSize: 14, boxShadow: "0 4px 20px rgba(0,0,0,0.4)" }}>
          {notification.msg}
        </div>
      )}

      {/* Header */}
      <div style={{ background: "rgba(255,255,255,0.03)", borderBottom: "1px solid rgba(255,255,255,0.08)", padding: "20px 32px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <div style={{ width: 40, height: 40, background: "linear-gradient(135deg, #00d4a0, #0080ff)", borderRadius: 10, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 20 }}>⚡</div>
          <div>
            <div style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, fontSize: 20, letterSpacing: "-0.5px" }}>Energie Dashboard</div>
            <div style={{ fontSize: 11, color: "#607898", marginTop: 1 }}>Verbruik · Opwek · Kosten · Laadvergoeding</div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {canSync && (
            <button onClick={doSync} disabled={syncing} style={{ padding: "8px 18px", borderRadius: 8, border: "none", cursor: syncing ? "not-allowed" : "pointer", fontSize: 13, fontFamily: "inherit", fontWeight: 600, background: syncing ? "rgba(255,255,255,0.07)" : "linear-gradient(135deg, #0080ff, #00d4a0)", color: syncing ? "#607898" : "#000", display: "flex", alignItems: "center", gap: 8, transition: "all 0.2s" }}>
              <span style={{ display: "inline-block", animation: syncing ? "spin 1s linear infinite" : "none" }}>↻</span>
              {syncing ? "Synchroniseren..." : "Sync"}
            </button>
          )}
          {[["dashboard","Dashboard"],["invoer","Invoer"],["vergelijk","Vergelijken"],["instellingen","⚙ Instellingen"]].map(([v,l]) => (
            <button key={v} onClick={() => setView(v)} style={{ padding: "8px 16px", borderRadius: 8, border: "none", cursor: "pointer", fontSize: 13, fontFamily: "inherit", fontWeight: 500, background: view === v ? "linear-gradient(135deg, #00d4a0, #0080ff)" : "rgba(255,255,255,0.07)", color: view === v ? "#000" : "#9ab", transition: "all 0.2s", position: "relative" }}>
              {l}
              {v === "instellingen" && !canSync && <span style={{ position: "absolute", top: 4, right: 4, width: 6, height: 6, borderRadius: "50%", background: "#f4a261" }} />}
            </button>
          ))}
        </div>
      </div>

      <div style={{ padding: "28px 32px", maxWidth: 1400, margin: "0 auto" }}>

        {view !== "instellingen" && (
          <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 28 }}>
            <span style={{ color: "#607898", fontSize: 13 }}>Jaar:</span>
            {years.map(y => (
              <button key={y} onClick={() => setSelectedYear(y)} style={{ padding: "6px 16px", borderRadius: 6, border: view === "vergelijk" && compareYear === y ? "2px solid #ff6b6b" : "none", cursor: "pointer", fontSize: 13, fontFamily: "inherit", fontWeight: 600, background: selectedYear === y ? "linear-gradient(135deg, #00d4a0, #0080ff)" : "rgba(255,255,255,0.07)", color: selectedYear === y ? "#000" : "#9ab" }}>
                {y}
              </button>
            ))}
            {years.length === 0 && <span style={{ color: "#607898", fontSize: 13, fontStyle: "italic" }}>Nog geen data – voeg data in via 'Invoer' of configureer sync via ⚙</span>}
          </div>
        )}

        {/* ===== DASHBOARD ===== */}
        {view === "dashboard" && (
          <div>
            {/* KPI row 1: energie */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 16, marginBottom: 16 }}>
              {[
                { label: "Totaal verbruik", value: fmt(totals.verbruik), icon: "🔌", color: "#4488ff", sub: `${yearData.length} maanden` },
                { label: "Totaal opgewekt", value: fmt(totals.opgewekt), icon: "☀️", color: "#00d4a0", sub: `${totals.opgewekt > 0 ? Math.round((totals.opgewekt/totals.verbruik)*100) : 0}% van verbruik` },
                { label: "Teruggeleverd", value: fmt(totals.teruggeleverd), icon: "↩️", color: "#f4a261", sub: `${totals.opgewekt > 0 ? Math.round((totals.teruggeleverd/totals.opgewekt)*100) : 0}% van opwek` },
                { label: "Zelfverbruik", value: fmt(Math.max(0, totals.opgewekt - totals.teruggeleverd)), icon: "🏠", color: "#818cf8",
                  sub: totals.opgewekt > 0
                    ? `${Math.round((Math.max(0, totals.opgewekt - totals.teruggeleverd) / totals.opgewekt) * 100)}% van opwek`
                    : "Nog geen opwekdata" },
                { label: "Bruto kosten", value: fmtEur(totals.kosten), icon: "💶", color: "#e76f51", sub: yearData.length > 0 ? `Ø ${fmtEur(totals.kosten/yearData.length)}/mnd` : "–" },
              ].map(card => (
                <KpiCard key={card.label} {...card} />
              ))}
            </div>

            {/* KPI row 2: vergoedingen + netto */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 16, marginBottom: 28 }}>
              <KpiCard label="Laadvergoeding EV (Eneco)" value={fmtEur(totals.laadvergoeding)} icon="🚗" color="#a78bfa"
                sub={totals.laadvergoeding > 0 ? `Ø ${fmtEur(totals.laadvergoeding / yearData.filter(r=>r.laadvergoeding>0).length)}/mnd` : "Nog geen data"} />
              <KpiCard label="Teruglevering vergoeding (Tibber)" value={fmtEur(totals.teruglevering_vergoeding)} icon="↩💶" color="#34d399"
                sub={totals.teruglevering_vergoeding > 0 ? `Ø ${fmtEur(totals.teruglevering_vergoeding / yearData.filter(r=>r.teruglevering_vergoeding>0).length)}/mnd` : "Nog geen data"} />
              <KpiCard label="Totale vergoedingen" value={fmtEur(totaleVergoeding)} icon="📊" color="#fbbf24"
                sub={`EV + teruglevering samen`} />
              <KpiCard label="Netto kosten" value={fmtEur(nettoKostenTotaal)} icon="✅" color="#00d4a0"
                sub={totaleVergoeding > 0 ? `${Math.round((totaleVergoeding/totals.kosten)*100)}% terugontvangen` : "Voer vergoedingen in"} accent />
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16, marginBottom: 16 }}>
              <ChartCard title="Verbruik vs Opgewekt (kWh)">
                <ResponsiveContainer width="100%" height={240}>
                  <AreaChart data={chartData}>
                    <defs>
                      <linearGradient id="gV" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#4488ff" stopOpacity={0.3}/><stop offset="95%" stopColor="#4488ff" stopOpacity={0}/></linearGradient>
                      <linearGradient id="gO" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#00d4a0" stopOpacity={0.3}/><stop offset="95%" stopColor="#00d4a0" stopOpacity={0}/></linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                    <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                    <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                    <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmt(v), ""]} />
                    <Legend wrapperStyle={{ fontSize: 12 }} />
                    <Area type="monotone" dataKey="verbruik" stroke="#4488ff" fill="url(#gV)" name="Verbruik" strokeWidth={2} connectNulls={false} />
                    <Area type="monotone" dataKey="opgewekt" stroke="#00d4a0" fill="url(#gO)" name="Opgewekt" strokeWidth={2} connectNulls={false} />
                  </AreaChart>
                </ResponsiveContainer>
              </ChartCard>

              <ChartCard title="Bruto kosten vs Netto kosten (€)">
                <ResponsiveContainer width="100%" height={240}>
                  <BarChart data={chartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                    <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                    <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                    <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmtEur(v), ""]} />
                    <Legend wrapperStyle={{ fontSize: 12 }} />
                    <Bar dataKey="kosten" fill="#e76f51" name="Bruto kosten" radius={[4,4,0,0]} />
                    <Bar dataKey="nettoKosten" fill="#00d4a0" name="Netto kosten" radius={[4,4,0,0]} />
                  </BarChart>
                </ResponsiveContainer>
              </ChartCard>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
              <ChartCard title="Teruggeleverd aan net (kWh)">
                <ResponsiveContainer width="100%" height={180}>
                  <BarChart data={chartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                    <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                    <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                    <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmt(v), ""]} />
                    <Bar dataKey="teruggeleverd" fill="#f4a261" name="Teruggeleverd" radius={[4,4,0,0]} />
                  </BarChart>
                </ResponsiveContainer>
              </ChartCard>

              <ChartCard title="Laadvergoeding Eneco eMobility (€)">
                <ResponsiveContainer width="100%" height={180}>
                  <BarChart data={chartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                    <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                    <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                    <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmtEur(v), ""]} />
                    <Bar dataKey="laadvergoeding" fill="#a78bfa" name="Laadvergoeding" radius={[4,4,0,0]} />
                  </BarChart>
                </ResponsiveContainer>
              </ChartCard>
            </div>
          </div>
        )}

        {/* ===== INVOER ===== */}
        {view === "invoer" && (
          <div>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 20 }}>
              <h2 style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, fontSize: 20, margin: 0 }}>Data invoeren – {selectedYear}</h2>
              <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                <button onClick={() => { setCsvModal(true); setCsvPreview(null); setCsvError(null); }} style={{ padding: "6px 14px", borderRadius: 6, border: "1px solid rgba(0,212,160,0.3)", cursor: "pointer", fontSize: 12, fontFamily: "inherit", background: "rgba(0,212,160,0.08)", color: "#00d4a0" }}>⬆ CSV importeren</button>
                <span style={{ color: "#607898", fontSize: 12 }}>Jaar toevoegen:</span>
                {allYearsForInput.filter(y => !years.includes(y)).slice(0,5).map(y => (
                  <button key={y} onClick={() => { openEdit(y, 1); setSelectedYear(y); }} style={{ padding: "5px 12px", borderRadius: 6, border: "1px solid rgba(255,255,255,0.15)", cursor: "pointer", fontSize: 12, fontFamily: "inherit", background: "transparent", color: "#9ab" }}>{y}</button>
                ))}
              </div>
            </div>
            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: 14, overflow: "hidden" }}>
              <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead>
                  <tr style={{ background: "rgba(255,255,255,0.05)" }}>
                    {["Maand","Verbruik (kWh)","Opgewekt (kWh)","Teruggelev. (kWh)","Kosten (€)","Laadverg. EV (€)","Teruglev. verg. (€)","Netto (€)",""].map(h => (
                      <th key={h} style={{ padding: "12px 14px", textAlign: "left", fontSize: 11, color: h === "Laadverg. EV (€)" ? "#a78bfa" : h === "Teruglev. verg. (€)" ? "#34d399" : "#607898", fontWeight: 500, letterSpacing: "0.04em", textTransform: "uppercase", whiteSpace: "nowrap" }}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {MAANDEN_LANG.map((naam, i) => {
                    const entry = yearData.find(r => r.maand === i+1);
                    const netto = entry ? (entry.kosten - (entry.laadvergoeding || 0) - (entry.teruglevering_vergoeding || 0)) : null;
                    return (
                      <tr key={i} style={{ borderTop: "1px solid rgba(255,255,255,0.05)" }} onMouseEnter={e => e.currentTarget.style.background="rgba(255,255,255,0.03)"} onMouseLeave={e => e.currentTarget.style.background="transparent"}>
                        <td style={{ padding: "11px 14px", fontWeight: 500, color: entry ? "#e8f0fe" : "#405060" }}>{naam}</td>
                        <td style={{ padding: "11px 14px", color: entry ? "#4488ff" : "#405060" }}>{entry ? fmt(entry.verbruik) : "–"}</td>
                        <td style={{ padding: "11px 14px", color: entry ? "#00d4a0" : "#405060" }}>{entry ? fmt(entry.opgewekt) : "–"}</td>
                        <td style={{ padding: "11px 14px", color: entry ? "#f4a261" : "#405060" }}>{entry ? fmt(entry.teruggeleverd) : "–"}</td>
                        <td style={{ padding: "11px 14px", color: entry ? "#e76f51" : "#405060" }}>{entry ? fmtEur(entry.kosten) : "–"}</td>
                        <td style={{ padding: "11px 14px", color: entry?.laadvergoeding > 0 ? "#a78bfa" : "#405060" }}>
                          {entry ? (entry.laadvergoeding > 0 ? fmtEur(entry.laadvergoeding) : <span style={{color:"#405060",fontSize:11}}>–</span>) : "–"}
                        </td>
                        <td style={{ padding: "11px 14px", color: entry?.teruglevering_vergoeding > 0 ? "#34d399" : "#405060" }}>
                          {entry ? (entry.teruglevering_vergoeding > 0 ? fmtEur(entry.teruglevering_vergoeding) : <span style={{color:"#405060",fontSize:11}}>–</span>) : "–"}
                        </td>
                        <td style={{ padding: "11px 14px", color: netto !== null ? (netto < entry.kosten ? "#00d4a0" : "#e76f51") : "#405060", fontWeight: netto !== null ? 600 : 400 }}>
                          {netto !== null ? fmtEur(netto) : "–"}
                        </td>
                        <td style={{ padding: "11px 14px", display: "flex", gap: 6 }}>
                          <button onClick={() => openEdit(selectedYear, i+1)} style={{ padding: "5px 12px", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontFamily: "inherit", background: "rgba(0,212,160,0.15)", color: "#00d4a0", whiteSpace: "nowrap" }}>{entry ? "Bewerken" : "+ Invoeren"}</button>
                          {entry && <button onClick={() => deleteEntry(selectedYear, i+1)} style={{ padding: "5px 10px", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontFamily: "inherit", background: "rgba(231,111,81,0.15)", color: "#e76f51" }}>✕</button>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* ===== VERGELIJK ===== */}
        {view === "vergelijk" && (
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 16, marginBottom: 24 }}>
              <div style={{ background: "rgba(0,212,160,0.1)", border: "1px solid rgba(0,212,160,0.3)", borderRadius: 8, padding: "8px 16px", fontSize: 13, color: "#00d4a0" }}>Jaar 1: <strong>{selectedYear}</strong></div>
              <span style={{ color: "#607898" }}>vs</span>
              <div style={{ display: "flex", gap: 6 }}>
                {years.filter(y => y !== selectedYear).map(y => (
                  <button key={y} onClick={() => setCompareYear(compareYear === y ? null : y)} style={{ padding: "6px 16px", borderRadius: 8, border: compareYear === y ? "2px solid #ff6b6b" : "1px solid rgba(255,255,255,0.15)", cursor: "pointer", fontSize: 13, fontFamily: "inherit", fontWeight: 600, background: compareYear === y ? "rgba(255,107,107,0.15)" : "transparent", color: compareYear === y ? "#ff6b6b" : "#9ab" }}>{y}</button>
                ))}
                {years.filter(y => y !== selectedYear).length === 0 && <span style={{ color: "#607898", fontSize: 13, fontStyle: "italic" }}>Voeg meer jaren toe via 'Invoer'</span>}
              </div>
            </div>
            {compareYear && (
              <>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 14, marginBottom: 24 }}>
                  {[
                    ["verbruik","Verbruik","#4488ff",false],
                    ["opgewekt","Opgewekt","#00d4a0",false],
                    ["teruggeleverd","Teruggelev.","#f4a261",false],
                    ["kosten","Bruto kosten","#e76f51",true],
                    ["laadvergoeding","Laadverg. EV","#a78bfa",true],
                    ["teruglevering_vergoeding","Teruglev. verg.","#34d399",true],
                  ].map(([key, label, color, isEur]) => {
                    const v1 = yearData.reduce((s,r) => s+(r[key]||0),0);
                    const v2 = compareData.reduce((s,r) => s+(r[key]||0),0);
                    const diff = v1 - v2;
                    const pct = v2 > 0 ? Math.round((diff/v2)*100) : null;
                    return (
                      <div key={key} style={{ background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: 12, padding: "16px 18px" }}>
                        <div style={{ fontSize: 10, color: "#607898", textTransform: "capitalize", marginBottom: 8 }}>{label}</div>
                        <div style={{ fontSize: 14, fontWeight: 600, color }}>{isEur ? fmtEur(v1) : fmt(v1)}</div>
                        <div style={{ fontSize: 12, color: "#607898", marginTop: 4 }}>{isEur ? fmtEur(v2) : fmt(v2)} ({compareYear})</div>
                        {pct !== null && <div style={{ fontSize: 11, color: diff < 0 ? "#00d4a0" : "#e76f51", marginTop: 5 }}>{diff > 0 ? "+" : ""}{pct}%</div>}
                      </div>
                    );
                  })}
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
                  <ChartCard title={`Verbruik: ${selectedYear} vs ${compareYear}`}>
                    <ResponsiveContainer width="100%" height={220}>
                      <LineChart data={chartData}>
                        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                        <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                        <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                        <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmt(v), ""]} />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <Line type="monotone" dataKey="verbruik" stroke="#4488ff" name={`${selectedYear}`} strokeWidth={2} dot={false} />
                        <Line type="monotone" dataKey={`verbruik_${compareYear}`} stroke="#4488ff" strokeDasharray="4 4" name={`${compareYear}`} strokeWidth={2} dot={false} />
                      </LineChart>
                    </ResponsiveContainer>
                  </ChartCard>
                  <ChartCard title={`Netto kosten: ${selectedYear} vs ${compareYear}`}>
                    <ResponsiveContainer width="100%" height={220}>
                      <BarChart data={chartData}>
                        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                        <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                        <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                        <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmtEur(v), ""]} />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <Bar dataKey="nettoKosten" fill="#00d4a0" name={`${selectedYear}`} radius={[4,4,0,0]} />
                        <Bar dataKey={`nettoKosten_${compareYear}`} fill="#007755" name={`${compareYear}`} radius={[4,4,0,0]} />
                      </BarChart>
                    </ResponsiveContainer>
                  </ChartCard>
                  <ChartCard title={`Opgewekt: ${selectedYear} vs ${compareYear}`}>
                    <ResponsiveContainer width="100%" height={220}>
                      <LineChart data={chartData}>
                        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                        <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                        <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                        <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmt(v), ""]} />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <Line type="monotone" dataKey="opgewekt" stroke="#00d4a0" name={`${selectedYear}`} strokeWidth={2} dot={false} />
                        <Line type="monotone" dataKey={`opgewekt_${compareYear}`} stroke="#00d4a0" strokeDasharray="4 4" name={`${compareYear}`} strokeWidth={2} dot={false} />
                      </LineChart>
                    </ResponsiveContainer>
                  </ChartCard>
                  <ChartCard title={`Bruto kosten: ${selectedYear} vs ${compareYear}`}>
                    <ResponsiveContainer width="100%" height={220}>
                      <BarChart data={chartData}>
                        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.05)" />
                        <XAxis dataKey="maand" tick={{ fill: "#607898", fontSize: 11 }} />
                        <YAxis tick={{ fill: "#607898", fontSize: 11 }} />
                        <Tooltip contentStyle={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8 }} formatter={(v) => [fmtEur(v), ""]} />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <Bar dataKey="kosten" fill="#e76f51" name={`${selectedYear}`} radius={[4,4,0,0]} />
                        <Bar dataKey={`kosten_${compareYear}`} fill="#9a3a22" name={`${compareYear}`} radius={[4,4,0,0]} />
                      </BarChart>
                    </ResponsiveContainer>
                  </ChartCard>
                </div>
              </>
            )}
            {!compareYear && years.length >= 2 && <div style={{ textAlign: "center", color: "#607898", padding: "60px 0", fontSize: 15 }}>Selecteer een vergelijkjaar hierboven</div>}
          </div>
        )}

        {/* ===== INSTELLINGEN ===== */}
        {view === "instellingen" && (
          <div style={{ maxWidth: 640 }}>
            <h2 style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, fontSize: 20, margin: "0 0 8px" }}>Instellingen & Synchronisatie</h2>
            <p style={{ color: "#607898", fontSize: 13, marginBottom: 28, lineHeight: 1.6 }}>Koppel Tibber en GoodWe SEMS om data automatisch op te halen. Je gegevens worden lokaal opgeslagen.</p>

            <Section title="Tibber" icon="⚡" badge={hasTibber ? "✓ Gekoppeld" : "Niet gekoppeld"} badgeOk={hasTibber}>
              <p style={{ color: "#607898", fontSize: 12, marginBottom: 16, lineHeight: 1.7 }}>
                Levert <strong style={{color:"#9ab"}}>verbruik (kWh) en kosten (€)</strong> per maand.<br/>
                Token ophalen via <a href="https://developer.tibber.com/explorer" target="_blank" rel="noreferrer" style={{ color: "#4488ff" }}>developer.tibber.com</a> → "Load personal token".
              </p>
              <Field label="Persoonlijk API Token">
                <input type="password" placeholder="Plak hier je Tibber token..." value={settings.tibber_token} onChange={e => setSettings(s => ({...s, tibber_token: e.target.value}))} style={inputStyle} />
              </Field>
            </Section>

            <Section title="GoodWe SEMSPlus" icon="☀️" badge={hasGoodwe ? "✓ Gekoppeld" : "Niet gekoppeld"} badgeOk={hasGoodwe}>
              <p style={{ color: "#607898", fontSize: 12, marginBottom: 16, lineHeight: 1.7 }}>
                Levert <strong style={{color:"#9ab"}}>opgewekt (kWh) en teruggeleverd (kWh)</strong> per maand.<br/>
                De app probeert automatisch het bewezen{" "}
                <a href="https://www.semsportal.com" target="_blank" rel="noreferrer" style={{ color: "#4488ff" }}>semsportal.com</a>{" "}
                eerst, en schakelt daarna over op het nieuwe{" "}
                <a href="https://semsplus.goodwe.com" target="_blank" rel="noreferrer" style={{ color: "#4488ff" }}>semsplus.goodwe.com</a>.{" "}
                Beide MD5 en plain-text wachtwoord worden geprobeerd.<br/><br/>
                <strong style={{color:"#9ab"}}>Station ID vinden in SEMSPlus:</strong> Log in → klik op je installatie → kopieer het ID uit de URL:<br/>
                <code style={{ background: "rgba(255,255,255,0.07)", padding: "3px 8px", borderRadius: 4, fontSize: 11, display: "inline-block", marginTop: 4 }}>
                  semsplus.goodwe.com/station/<strong style={{color:"#00d4a0"}}>JOUW-ID</strong>/overview
                </code>
              </p>
              <Field label="E-mailadres">
                <input type="email" placeholder="jouw@email.nl" value={settings.goodwe_email} onChange={e => setSettings(s => ({...s, goodwe_email: e.target.value}))} style={inputStyle} />
              </Field>
              <Field label={settings.goodwe_has_password ? "Wachtwoord (opgeslagen – laat leeg om te behouden)" : "Wachtwoord"}>
                <input type="password" placeholder={settings.goodwe_has_password ? "••••••••" : "SEMSPlus wachtwoord"} value={settings.goodwe_password} onChange={e => setSettings(s => ({...s, goodwe_password: e.target.value}))} style={inputStyle} />
              </Field>
              <Field label="Station ID">
                <input type="text" placeholder="12345678-abcd-1234-efgh-123456789012" value={settings.goodwe_station_id} onChange={e => setSettings(s => ({...s, goodwe_station_id: e.target.value}))} style={inputStyle} />
              </Field>
            </Section>

            <Section title="Eneco eMobility" icon="🚗" badge="Handmatig" badgeOk={false}>
              <p style={{ color: "#607898", fontSize: 12, lineHeight: 1.7 }}>
                Eneco eMobility heeft helaas <strong style={{color:"#e76f51"}}>geen publieke API</strong> beschikbaar voor de vergoedingsdata.<br/>
                Voer de maandelijkse laadvergoeding handmatig in via de <strong style={{color:"#9ab"}}>Invoer</strong> pagina (het veld "Laadvergoeding EV").<br/><br/>
                Het bedrag staat op je maandelijkse Eneco eMobility factuur of in de app onder <em>Laadvergoeding</em>.
              </p>
            </Section>

            <div style={{ display: "flex", gap: 12, marginBottom: 24 }}>
              <button onClick={saveSettings} disabled={savingSettings} style={{ padding: "11px 24px", borderRadius: 8, border: "none", cursor: "pointer", fontSize: 14, fontFamily: "inherit", fontWeight: 600, background: "linear-gradient(135deg, #00d4a0, #0080ff)", color: "#000" }}>
                {savingSettings ? "Opslaan..." : "Instellingen opslaan"}
              </button>
              {canSync && (
                <button onClick={doSync} disabled={syncing} style={{ padding: "11px 24px", borderRadius: 8, border: "none", cursor: syncing ? "not-allowed" : "pointer", fontSize: 14, fontFamily: "inherit", fontWeight: 600, background: syncing ? "rgba(255,255,255,0.07)" : "rgba(0,128,255,0.15)", color: syncing ? "#607898" : "#4488ff" }}>
                  {syncing ? "↻ Bezig..." : "↻ Nu synchroniseren"}
                </button>
              )}
            </div>

            {syncResult && (
              <div style={{ background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 12, padding: 20, marginBottom: 24 }}>
                <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 12, color: "#9ab" }}>Laatste sync resultaat</div>
                {syncResult.tibber && <div style={{ fontSize: 13, color: "#00d4a0", marginBottom: 6 }}>✓ Tibber: {syncResult.tibber}</div>}
                {syncResult.goodwe && <div style={{ fontSize: 13, color: "#00d4a0", marginBottom: 6 }}>✓ GoodWe: {syncResult.goodwe}</div>}
                {syncResult.errors?.map((e,i) => <div key={i} style={{ fontSize: 12, color: "#ff6666", marginTop: 6 }}>✗ {e}</div>)}
              </div>
            )}

            <div style={{ background: "rgba(0,128,255,0.06)", border: "1px solid rgba(0,128,255,0.18)", borderRadius: 12, padding: 20 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: "#6ab", marginBottom: 10 }}>ℹ Databronnen overzicht</div>
              <div style={{ fontSize: 12, color: "#607898", lineHeight: 1.8 }}>
                • <strong style={{color:"#9ab"}}>Tibber</strong> → verbruik + kosten via API (automatisch)<br/>
                • <strong style={{color:"#9ab"}}>GoodWe SEMSPlus</strong> → opgewekt + teruggeleverd via API (automatisch, met terugval op oud portal)<br/>
                • <strong style={{color:"#a78bfa"}}>Eneco eMobility</strong> → laadvergoeding handmatig invoeren (geen API)<br/>
                • Handmatige invoer wordt nooit overschreven door sync
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Edit Modal */}
      {editModal && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.7)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setEditModal(null)}>
          <div style={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 16, padding: 32, width: 420, maxWidth: "90vw" }} onClick={e => e.stopPropagation()}>
            <h3 style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, margin: "0 0 24px", fontSize: 18 }}>
              {MAANDEN_LANG[editModal.maand-1]} {editModal.jaar}
            </h3>
            {[
              ["verbruik","Verbruik","kWh","#4488ff"],
              ["opgewekt","Opgewekt door zonnepanelen","kWh","#00d4a0"],
              ["teruggeleverd","Teruggeleverd aan net","kWh","#f4a261"],
              ["kosten","Bruto kosten","€","#e76f51"],
              ["laadvergoeding","Laadvergoeding Eneco eMobility","€","#a78bfa"],
              ["teruglevering_vergoeding","Teruglevering vergoeding (Tibber)","€","#34d399"],
            ].map(([key, label, unit, color]) => (
              <div key={key} style={{ marginBottom: 14 }}>
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "#607898", marginBottom: 6 }}>
                  <span style={{ width: 8, height: 8, borderRadius: "50%", background: color, display: "inline-block" }} />
                  {label} ({unit})
                </label>
                <input type="number" step="0.01" min="0" value={form[key] || ""} onChange={e => setForm(f => ({...f, [key]: e.target.value}))}
                  placeholder={key === "laadvergoeding" || key === "teruglevering_vergoeding" ? "0.00 – optioneel" : ""}
                  style={{ ...inputStyle, borderColor: form[key] > 0 && (key === "laadvergoeding" || key === "teruglevering_vergoeding") ? `rgba(${key === "laadvergoeding" ? "167,139,250" : "52,211,153"},0.4)` : "rgba(255,255,255,0.12)" }} />
              </div>
            ))}
            {(form.kosten > 0 || form.laadvergoeding > 0 || form.teruglevering_vergoeding > 0) && (
              <div style={{ background: "rgba(0,212,160,0.08)", border: "1px solid rgba(0,212,160,0.2)", borderRadius: 8, padding: "10px 14px", marginBottom: 14, fontSize: 13 }}>
                Netto kosten: <strong style={{color:"#00d4a0"}}>{fmtEur((Number(form.kosten)||0) - (Number(form.laadvergoeding)||0) - (Number(form.teruglevering_vergoeding)||0))}</strong>
                {(form.laadvergoeding > 0 || form.teruglevering_vergoeding > 0) && (
                  <span style={{color:"#607898", fontSize:11, marginLeft:8}}>
                    ({form.laadvergoeding > 0 ? `EV ${fmtEur(Number(form.laadvergoeding))}` : ""}{form.laadvergoeding > 0 && form.teruglevering_vergoeding > 0 ? " + " : ""}{form.teruglevering_vergoeding > 0 ? `teruglev. ${fmtEur(Number(form.teruglevering_vergoeding))}` : ""})
                  </span>
                )}
              </div>
            )}
            <div style={{ display: "flex", gap: 10, marginTop: 20 }}>
              <button onClick={saveForm} disabled={saving} style={{ flex: 1, padding: "11px 0", borderRadius: 8, border: "none", cursor: "pointer", fontSize: 14, fontFamily: "inherit", fontWeight: 600, background: "linear-gradient(135deg, #00d4a0, #0080ff)", color: "#000" }}>
                {saving ? "Opslaan..." : "Opslaan"}
              </button>
              <button onClick={() => setEditModal(null)} style={{ padding: "11px 18px", borderRadius: 8, border: "1px solid rgba(255,255,255,0.15)", cursor: "pointer", fontSize: 14, fontFamily: "inherit", background: "transparent", color: "#9ab" }}>
                Annuleren
              </button>
            </div>
          </div>
        </div>
      )}

      {/* CSV Import Modal */}
      {csvModal && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.75)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setCsvModal(false)}>
          <div style={{ background: "#0d1929", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 16, padding: 32, width: 680, maxWidth: "95vw", maxHeight: "85vh", overflowY: "auto" }} onClick={e => e.stopPropagation()}>
            <h3 style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, margin: "0 0 6px", fontSize: 18 }}>CSV importeren</h3>
            <p style={{ color: "#607898", fontSize: 13, margin: "0 0 20px" }}>Importeer meerdere maanden tegelijk. Bestaande data wordt overschreven.</p>

            {/* Format explanation */}
            <div style={{ background: "rgba(0,212,160,0.06)", border: "1px solid rgba(0,212,160,0.2)", borderRadius: 10, padding: "14px 16px", marginBottom: 20, fontSize: 12 }}>
              <div style={{ color: "#00d4a0", fontWeight: 600, marginBottom: 8 }}>📋 Verwacht CSV-formaat</div>
              <div style={{ color: "#607898", marginBottom: 8 }}>Verplichte kolommen (komma of puntkomma als scheidingsteken):</div>
              <code style={{ display: "block", background: "rgba(0,0,0,0.3)", borderRadius: 6, padding: "8px 12px", color: "#e8f0fe", fontFamily: "monospace", fontSize: 11, lineHeight: 1.8, whiteSpace: "pre-wrap" }}>
{`jaar;maand;verbruik;opgewekt;teruggeleverd;kosten;laadvergoeding;teruglevering_vergoeding
2024;1;342.5;180.2;95.1;89.34;12.50;8.20
2024;2;298.7;210.4;110.6;76.15;11.80;9.40`}
              </code>
              <div style={{ color: "#607898", marginTop: 10, lineHeight: 1.7 }}>
                • <strong style={{color:"#9ab"}}>jaar</strong> — 4-cijferig jaar (bijv. 2024)<br/>
                • <strong style={{color:"#9ab"}}>maand</strong> — 1 t/m 12<br/>
                • <strong style={{color:"#9ab"}}>verbruik / opgewekt / teruggeleverd</strong> — kWh (decimaal met punt of komma)<br/>
                • <strong style={{color:"#9ab"}}>kosten</strong> — bruto kosten in € (decimaal)<br/>
                • <strong style={{color:"#607898"}}>laadvergoeding / teruglevering_vergoeding</strong> — optioneel, € (0 als leeg)
              </div>
            </div>

            {/* File drop zone */}
            <div
              style={{ border: "2px dashed rgba(255,255,255,0.15)", borderRadius: 10, padding: "28px 20px", textAlign: "center", marginBottom: 16, cursor: "pointer", transition: "border-color 0.2s" }}
              onDragOver={e => { e.preventDefault(); e.currentTarget.style.borderColor = "#00d4a0"; }}
              onDragLeave={e => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.15)"; }}
              onDrop={e => { e.preventDefault(); e.currentTarget.style.borderColor = "rgba(255,255,255,0.15)"; handleCsvFile(e.dataTransfer.files[0]); }}
              onClick={() => document.getElementById("csvFileInput").click()}
            >
              <div style={{ fontSize: 28, marginBottom: 8 }}>📂</div>
              <div style={{ color: "#9ab", fontSize: 13 }}>Klik om een CSV-bestand te kiezen, of sleep het hierheen</div>
              <input id="csvFileInput" type="file" accept=".csv,.txt" style={{ display: "none" }} onChange={e => handleCsvFile(e.target.files[0])} />
            </div>

            {/* Error */}
            {csvError && (
              <div style={{ background: "rgba(231,111,81,0.1)", border: "1px solid rgba(231,111,81,0.3)", borderRadius: 8, padding: "10px 14px", marginBottom: 16, color: "#e76f51", fontSize: 13 }}>
                ⚠ {csvError}
              </div>
            )}

            {/* Preview table */}
            {csvPreview && (
              <div>
                <div style={{ color: "#00d4a0", fontSize: 13, fontWeight: 600, marginBottom: 10 }}>
                  ✓ {csvPreview.length} rijen gevonden — controleer en bevestig import:
                </div>
                <div style={{ overflowX: "auto", maxHeight: 260, overflowY: "auto", borderRadius: 8, border: "1px solid rgba(255,255,255,0.08)" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
                    <thead>
                      <tr style={{ background: "rgba(255,255,255,0.06)", position: "sticky", top: 0 }}>
                        {["Jaar","Maand","Verbruik","Opgewekt","Teruggelev.","Kosten","Laadverg.","TL Verg."].map(h => (
                          <th key={h} style={{ padding: "8px 10px", textAlign: "left", color: "#607898", fontWeight: 500, whiteSpace: "nowrap" }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {csvPreview.map((r, i) => (
                        <tr key={i} style={{ borderTop: "1px solid rgba(255,255,255,0.05)" }}>
                          <td style={{ padding: "7px 10px", color: "#9ab" }}>{r.jaar}</td>
                          <td style={{ padding: "7px 10px", color: "#9ab" }}>{MAANDEN[r.maand-1]}</td>
                          <td style={{ padding: "7px 10px", color: "#4488ff" }}>{r.verbruik}</td>
                          <td style={{ padding: "7px 10px", color: "#00d4a0" }}>{r.opgewekt}</td>
                          <td style={{ padding: "7px 10px", color: "#f4a261" }}>{r.teruggeleverd}</td>
                          <td style={{ padding: "7px 10px", color: "#e76f51" }}>€{r.kosten}</td>
                          <td style={{ padding: "7px 10px", color: "#a78bfa" }}>{r.laadvergoeding > 0 ? `€${r.laadvergoeding}` : "–"}</td>
                          <td style={{ padding: "7px 10px", color: "#34d399" }}>{r.teruglevering_vergoeding > 0 ? `€${r.teruglevering_vergoeding}` : "–"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            <div style={{ display: "flex", gap: 10, marginTop: 20 }}>
              <button onClick={importCsvRows} disabled={!csvPreview || csvImporting} style={{ flex: 1, padding: "11px 0", borderRadius: 8, border: "none", cursor: csvPreview ? "pointer" : "not-allowed", fontSize: 14, fontFamily: "inherit", fontWeight: 600, background: csvPreview ? "linear-gradient(135deg, #00d4a0, #0080ff)" : "rgba(255,255,255,0.1)", color: csvPreview ? "#000" : "#607898" }}>
                {csvImporting ? "Importeren..." : `Importeer ${csvPreview?.length ?? 0} rijen`}
              </button>
              <button onClick={() => setCsvModal(false)} style={{ padding: "11px 18px", borderRadius: 8, border: "1px solid rgba(255,255,255,0.15)", cursor: "pointer", fontSize: 14, fontFamily: "inherit", background: "transparent", color: "#9ab" }}>
                Annuleren
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function KpiCard({ label, value, icon, color, sub, accent, extraLine }) {
  return (
    <div style={{ background: accent ? "rgba(0,212,160,0.06)" : "rgba(255,255,255,0.04)", border: `1px solid ${accent ? "rgba(0,212,160,0.25)" : "rgba(255,255,255,0.08)"}`, borderRadius: 14, padding: "20px 22px" }}>
      <div style={{ fontSize: 22, marginBottom: 8 }}>{icon}</div>
      <div style={{ fontSize: 22, fontWeight: 600, color, fontFamily: "'Space Grotesk', sans-serif" }}>{value}</div>
      <div style={{ fontSize: 11, color: "#607898", marginTop: 4 }}>{label}</div>
      <div style={{ fontSize: 11, color: "#405060", marginTop: 2 }}>{sub}</div>
      {extraLine && <div style={{ fontSize: 11, color: "#405060", marginTop: 1 }}>{extraLine}</div>}
    </div>
  );
}

function Section({ title, icon, badge, badgeOk, children }) {
  return (
    <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: 14, padding: "20px 24px", marginBottom: 20 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 16 }}>
        <span style={{ fontSize: 18 }}>{icon}</span>
        <span style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, fontSize: 16 }}>{title}</span>
        <span style={{ fontSize: 11, padding: "3px 10px", borderRadius: 20, background: badgeOk ? "rgba(0,212,160,0.15)" : "rgba(255,255,255,0.07)", color: badgeOk ? "#00d4a0" : "#607898", marginLeft: "auto" }}>{badge}</span>
      </div>
      {children}
    </div>
  );
}

function Field({ label, children }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <label style={{ display: "block", fontSize: 12, color: "#607898", marginBottom: 6 }}>{label}</label>
      {children}
    </div>
  );
}

function ChartCard({ title, children }) {
  return (
    <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: 14, padding: "20px 20px 12px" }}>
      <div style={{ fontSize: 12, color: "#607898", marginBottom: 16, fontWeight: 500, letterSpacing: "0.04em", textTransform: "uppercase" }}>{title}</div>
      {children}
    </div>
  );
}
