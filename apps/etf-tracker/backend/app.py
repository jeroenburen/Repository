from flask import Flask, request, jsonify
from flask_cors import CORS
import pandas as pd
import json
import os
import io
from datetime import datetime
import sqlite3

app = Flask(__name__)
CORS(app)

DB_PATH = "/data/etf_tracker.db"

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS deposits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            year INTEGER,
            month INTEGER,
            day INTEGER,
            amount REAL,
            weighted_amount REAL,
            note TEXT
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS portfolio_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            snapshot_date TEXT,
            total_value REAL,
            positions TEXT
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS target_allocations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product TEXT UNIQUE,
            target_pct REAL
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS year_saldi (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            year INTEGER UNIQUE,
            begin_waarde REAL,
            eind_waarde REAL
        )
    """)
    conn.commit()
    conn.close()

init_db()

def calculate_weight(day, month, year):
    try:
        date = datetime(year, month, day)
        year_start = datetime(year, 1, 1)
        year_end = datetime(year, 12, 31)
        total_days = (year_end - year_start).days
        days_remaining = (year_end - date).days
        return round(days_remaining / total_days, 4)
    except:
        return 0

def clean_number(val):
    """Parse European (1.234,56) or US (1,234.56) formatted numbers."""
    s = str(val).strip().replace("€", "").replace(" ", "").replace("\xa0", "")
    if s in ("", "nan", "-", "N/A", "none", "None"):
        return None
    if "," in s and "." in s:
        if s.rindex(",") > s.rindex("."):
            s = s.replace(".", "").replace(",", ".")
        else:
            s = s.replace(",", "")
    elif "," in s:
        parts = s.split(",")
        if len(parts) == 2 and len(parts[1]) <= 2:
            s = s.replace(",", ".")
        else:
            s = s.replace(",", "")
    try:
        return float(s)
    except:
        return None

@app.route("/api/health")
def health():
    return jsonify({"status": "ok"})

@app.route("/api/upload-csv", methods=["POST"])
def upload_csv():
    if "file" not in request.files:
        return jsonify({"error": "No file"}), 400
    file = request.files["file"]
    try:
        raw = file.read()
        sample = raw[:1000].decode("utf-8", errors="replace")
        sep = ";" if sample.count(";") > sample.count(",") else ","
        df = pd.read_csv(io.BytesIO(raw), sep=sep, skip_blank_lines=True)
        df.columns = [str(c).strip() for c in df.columns]

        # Find columns by name
        col_product = None
        col_aantal = None
        col_koers = None
        col_waarde = None

        for col in df.columns:
            cl = col.lower()
            if "product" in cl and col_product is None:
                col_product = col
            elif "aantal" in cl:
                col_aantal = col
            elif "slotkoers" in cl or "koers" in cl:
                col_koers = col
            elif "waarde in eur" in cl:
                col_waarde = col
            elif cl.startswith("waarde") and "eur" in cl and col_waarde is None:
                col_waarde = col

        if col_product is None:
            cols = list(df.columns)
            col_product = cols[0]
            if len(cols) > 2: col_aantal = cols[2]
            if len(cols) > 3: col_koers = cols[3]
            if len(cols) > 6: col_waarde = cols[6]

        positions = []
        for _, row in df.iterrows():
            product = str(row[col_product]).strip()
            if not product or product.lower() in ("nan", "product", ""):
                continue

            # Skip cash rows
            if "cash" in product.lower():
                continue

            aantal = clean_number(row[col_aantal]) if col_aantal else None
            koers = clean_number(row[col_koers]) if col_koers else None

            # Try waarde column first, fall back to aantal * koers
            waarde = None
            if col_waarde:
                waarde = clean_number(row[col_waarde])
            if (waarde is None or waarde <= 0) and aantal and koers:
                waarde = round(aantal * koers, 2)

            if waarde is None or waarde <= 0:
                continue

            positions.append({
                "product": product,
                "aantal": aantal,
                "waarde": waarde
            })

        if not positions:
            return jsonify({"error": "Geen geldige posities gevonden in CSV"}), 400

        total = sum(p["waarde"] for p in positions)
        for p in positions:
            p["pct"] = round(p["waarde"] / total * 100, 2) if total > 0 else 0

        conn = get_db()
        conn.execute(
            "INSERT INTO portfolio_snapshots (snapshot_date, total_value, positions) VALUES (?, ?, ?)",
            (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), total, json.dumps(positions))
        )
        conn.commit()
        conn.close()

        return jsonify({"positions": positions, "total": total})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/deposits", methods=["GET"])
def get_deposits():
    year = request.args.get("year", datetime.now().year, type=int)
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM deposits WHERE year=? ORDER BY month, day", (year,)
    ).fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/deposits", methods=["POST"])
def add_deposit():
    data = request.json
    year = data.get("year", datetime.now().year)
    month = data.get("month")
    day = data.get("day")
    amount = data.get("amount")
    note = data.get("note", "")
    weight = calculate_weight(day, month, year)
    weighted = round(amount * weight, 2)
    conn = get_db()
    conn.execute(
        "INSERT INTO deposits (year, month, day, amount, weighted_amount, note) VALUES (?,?,?,?,?,?)",
        (year, month, day, amount, weighted, note)
    )
    conn.commit()
    conn.close()
    return jsonify({"success": True, "weight": weight, "weighted_amount": weighted})

@app.route("/api/deposits/<int:dep_id>", methods=["DELETE"])
def delete_deposit(dep_id):
    conn = get_db()
    conn.execute("DELETE FROM deposits WHERE id=?", (dep_id,))
    conn.commit()
    conn.close()
    return jsonify({"success": True})

@app.route("/api/deposits/years")
def get_years():
    conn = get_db()
    rows = conn.execute("SELECT DISTINCT year FROM deposits ORDER BY year").fetchall()
    conn.close()
    years = [r["year"] for r in rows]
    current = datetime.now().year
    if current not in years:
        years.append(current)
    return jsonify(sorted(years))

@app.route("/api/targets", methods=["GET"])
def get_targets():
    conn = get_db()
    rows = conn.execute("SELECT * FROM target_allocations").fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/targets", methods=["POST"])
def set_target():
    data = request.json
    product = data.get("product")
    target_pct = data.get("target_pct")
    conn = get_db()
    conn.execute(
        "INSERT INTO target_allocations (product, target_pct) VALUES (?,?) ON CONFLICT(product) DO UPDATE SET target_pct=?",
        (product, target_pct, target_pct)
    )
    conn.commit()
    conn.close()
    return jsonify({"success": True})

@app.route("/api/snapshots")
def get_snapshots():
    conn = get_db()
    rows = conn.execute(
        "SELECT snapshot_date, total_value FROM portfolio_snapshots ORDER BY snapshot_date"
    ).fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/snapshots/latest")
def get_latest_snapshot():
    conn = get_db()
    row = conn.execute(
        "SELECT * FROM portfolio_snapshots ORDER BY id DESC LIMIT 1"
    ).fetchone()
    conn.close()
    if not row:
        return jsonify(None)
    d = dict(row)
    d["positions"] = json.loads(d["positions"])
    return jsonify(d)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)

@app.route("/api/year-saldi", methods=["GET"])
def get_year_saldi():
    conn = get_db()
    rows = conn.execute("SELECT * FROM year_saldi ORDER BY year").fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/year-saldi", methods=["POST"])
def set_year_saldi():
    data = request.json
    year = data.get("year")
    begin = data.get("begin_waarde")
    eind = data.get("eind_waarde")
    conn = get_db()
    conn.execute("""
        INSERT INTO year_saldi (year, begin_waarde, eind_waarde)
        VALUES (?,?,?)
        ON CONFLICT(year) DO UPDATE SET begin_waarde=?, eind_waarde=?
    """, (year, begin, eind, begin, eind))
    conn.commit()
    conn.close()
    return jsonify({"success": True})
