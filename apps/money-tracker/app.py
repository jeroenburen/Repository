from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
import sqlite3
import os
import xml.etree.ElementTree as ET
from datetime import datetime
import re
import json
import google.generativeai as genai

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

app = Flask(__name__,
            template_folder=os.path.join(BASE_DIR, 'templates'),
            static_folder=os.path.join(BASE_DIR, 'static'))
CORS(app)
app.config['MAX_CONTENT_LENGTH'] = 256 * 1024 * 1024  # 256 MB

DB_PATH = os.environ.get('DB_PATH', '/data/fintrack.db')


# ── Database ──────────────────────────────────────────────────────────────────

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS transactions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            date        TEXT NOT NULL,
            amount      REAL NOT NULL,
            description TEXT,
            counterpart TEXT,
            iban        TEXT,
            ref         TEXT,
            category    TEXT,
            subcategory TEXT,
            manual      INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS rules (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT,
            field       TEXT NOT NULL,
            match_type  TEXT NOT NULL,
            pattern     TEXT NOT NULL,
            category    TEXT NOT NULL,
            subcategory TEXT NOT NULL,
            priority    INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS imports (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            filename    TEXT,
            imported_at TEXT,
            count       INTEGER
        );
        CREATE TABLE IF NOT EXISTS categories (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            name     TEXT NOT NULL UNIQUE,
            color    TEXT NOT NULL DEFAULT '#666666',
            sort_order INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS subcategories (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
            name        TEXT NOT NULL,
            sort_order  INTEGER DEFAULT 0,
            UNIQUE(category_id, name)
        );
    """)

    # Migration: if the existing transactions table still has a UNIQUE index on ref, rebuild it
    table_sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='transactions'").fetchone()
    if table_sql and 'UNIQUE' in (table_sql['sql'] or '').upper():
        conn.executescript("""
            BEGIN;
            ALTER TABLE transactions RENAME TO transactions_old;
            CREATE TABLE transactions (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                date        TEXT NOT NULL,
                amount      REAL NOT NULL,
                description TEXT,
                counterpart TEXT,
                iban        TEXT,
                ref         TEXT,
                category    TEXT,
                subcategory TEXT,
                manual      INTEGER DEFAULT 0
            );
            INSERT INTO transactions SELECT * FROM transactions_old;
            DROP TABLE transactions_old;
            COMMIT;
        """)

    # Seed default categories if table is empty
    if conn.execute("SELECT COUNT(*) FROM categories").fetchone()[0] == 0:
        defaults = [
            ("Vaste Lasten",            "#E63946", 1, ["Hypotheek","Gas Water Licht","Verzekeringen","Belastingen","Onderhoudscontracten","Zak- en kleedgeld","Loterijen"]),
            ("Huishouden",              "#F4A261", 2, ["Boodschappen","Drogisterij","Persoonlijke verzorging","Klussen & Onderhoud","Overig huishouden"]),
            ("Auto & Vervoer",          "#2A9D8F", 3, ["Parkeren","Openbaar Vervoer","Fiets"]),
            ("Abonnementen & Media",    "#457B9D", 4, ["Internet, TV en Mobiel","Lidmaatschappen"]),
            ("Lifestyle & Ontspanning", "#E9C46A", 5, ["Horeca","Uitgaan","Kleding","Vakantie","Cadeaus","Woning & Tuin"]),
            ("Inkomsten",               "#52B788", 6, ["Salaris","Belastingteruggave"]),
            ("Sparen",                  "#9B72CF", 7, []),
            ("Beleggen",                "#7B52AF", 8, []),
        ]
        for name, color, order, subs in defaults:
            cur = conn.execute("INSERT INTO categories (name, color, sort_order) VALUES (?,?,?)", (name, color, order))
            cat_id = cur.lastrowid
            for i, sub in enumerate(subs):
                conn.execute("INSERT INTO subcategories (category_id, name, sort_order) VALUES (?,?,?)", (cat_id, sub, i))

    conn.commit()

    # Migration: split 'Sparen & Beleggen' into separate 'Sparen' and 'Beleggen' categories
    old_cat = conn.execute("SELECT id FROM categories WHERE name='Sparen & Beleggen'").fetchone()
    if old_cat:
        old_id = old_cat['id']
        max_order = conn.execute("SELECT COALESCE(MAX(sort_order),0) FROM categories").fetchone()[0]
        for i, (new_name, new_color) in enumerate([("Sparen", "#9B72CF"), ("Beleggen", "#7B52AF")]):
            exists = conn.execute("SELECT id FROM categories WHERE name=?", (new_name,)).fetchone()
            if not exists:
                conn.execute(
                    "INSERT INTO categories (name, color, sort_order) VALUES (?,?,?)",
                    (new_name, new_color, max_order + i + 1)
                )
            # Move transactions: subcategory matches new category name -> set as top-level category
            conn.execute(
                "UPDATE transactions SET category=?, subcategory='' WHERE category='Sparen & Beleggen' AND subcategory=?",
                (new_name, new_name)
            )
            # Move matching rules
            conn.execute(
                "UPDATE rules SET category=?, subcategory='' WHERE category='Sparen & Beleggen' AND subcategory=?",
                (new_name, new_name)
            )
        # Any remaining transactions without a matched subcategory go to 'Sparen'
        conn.execute(
            "UPDATE transactions SET category='Sparen', subcategory='' WHERE category='Sparen & Beleggen'"
        )
        conn.execute(
            "UPDATE rules SET category='Sparen', subcategory='' WHERE category='Sparen & Beleggen'"
        )
        # Remove old category (cascades to subcategories table)
        conn.execute("DELETE FROM categories WHERE id=?", (old_id,))
        conn.commit()

    conn.close()

# ── CAMT.053 Parser ───────────────────────────────────────────────────────────

def collect_namespaces(xml_bytes):
    """Collect all unique namespace URIs declared anywhere in the document."""
    ns_uris = set()
    for event, (prefix, uri) in ET.iterparse(
            __import__('io').BytesIO(xml_bytes), events=['start-ns']):
        ns_uris.add(uri)
    return ns_uris

def tag_local(el):
    """Return local tag name without namespace."""
    return re.sub(r'\{[^}]*\}', '', el.tag)

def find_local(el, *local_names):
    """
    Walk the subtree of `el` and return the first element whose local tag
    matches any of local_names (in order).  Returns None if not found.
    """
    for name in local_names:
        for child in el.iter():
            if tag_local(child) == name:
                return child
    return None

def findall_local(el, local_name):
    return [c for c in el.iter() if tag_local(c) == local_name]

def findtext_local(el, *local_names):
    node = find_local(el, *local_names)
    return (node.text or '').strip() if node is not None else ''

def parse_camt053(xml_bytes):
    """Parse all <Ntry> blocks from a CAMT.053 XML file.
    <Ntry> elements are always direct children of <Stmt>.
    <Bal> blocks are siblings of <Ntry> and are explicitly skipped.
    """
    root = ET.fromstring(xml_bytes)
    transactions = []

    # Find all <Stmt> elements (there may be multiple accounts in one file)
    for stmt in root.iter():
        if tag_local(stmt) != 'Stmt':
            continue

        # Only direct children of <Stmt> with local tag 'Ntry'
        for entry in stmt:
            if tag_local(entry) != 'Ntry':
                continue  # skips Bal, GrpHdr, Acct, etc.

            # Amount: direct child <Amt> of this <Ntry>
            amt_el = next((c for c in entry if tag_local(c) == 'Amt'), None)
            if amt_el is None or not (amt_el.text or '').strip():
                continue
            try:
                amount = float(amt_el.text.strip().replace(',', '.'))
            except ValueError:
                continue

            # Debit or credit
            cdt_dbt = findtext_local(entry, 'CdtDbtInd').upper()
            amount = -abs(amount) if cdt_dbt == 'DBIT' else abs(amount)

            # Date: BookgDt preferred, fall back to ValDt
            date_str = ''
            for container in ['BookgDt', 'ValDt']:
                dc = find_local(entry, container)
                if dc is not None:
                    dt = find_local(dc, 'Dt', 'DtTm')
                    if dt is not None and dt.text:
                        date_str = dt.text.strip()[:10]
                        break

            # Reference: NtryRef (ASN Bank), AcctSvcrRef, EndToEndId, TxId
            ref = (findtext_local(entry, 'NtryRef') or
                   findtext_local(entry, 'AcctSvcrRef') or
                   findtext_local(entry, 'EndToEndId') or
                   findtext_local(entry, 'TxId') or '')

            # Description: Ustrd remittance info + AddtlNtryInf
            desc_parts = []
            for node in findall_local(entry, 'Ustrd'):
                if node.text and node.text.strip():
                    desc_parts.append(node.text.strip())
            for node in findall_local(entry, 'AddtlNtryInf'):
                if node.text and node.text.strip():
                    desc_parts.append(node.text.strip())
            description = ' | '.join(dict.fromkeys(desc_parts))

            # Counterpart name
            counterpart = ''
            rp = find_local(entry, 'RltdPties')
            if rp is not None:
                for party_tag in (['Cdtr', 'Dbtr'] if cdt_dbt == 'DBIT' else ['Dbtr', 'Cdtr']):
                    party = find_local(rp, party_tag)
                    if party is not None:
                        nm = find_local(party, 'Nm')
                        if nm is not None and nm.text and nm.text.strip():
                            counterpart = nm.text.strip()
                            break

            # Counterpart IBAN
            iban = ''
            if rp is not None:
                for acct_tag in (['CdtrAcct', 'DbtrAcct'] if cdt_dbt == 'DBIT' else ['DbtrAcct', 'CdtrAcct']):
                    acct = find_local(rp, acct_tag)
                    if acct is not None:
                        iban_el = find_local(acct, 'IBAN')
                        if iban_el is not None and iban_el.text:
                            iban = iban_el.text.strip()
                            break

            if not ref:
                ref = f'{date_str}|{amount}|{iban or counterpart}|{description[:60]}'

            transactions.append({
                'date': date_str, 'amount': amount,
                'description': description, 'counterpart': counterpart,
                'iban': iban, 'ref': ref,
            })

    return transactions

# ── Rule Engine ───────────────────────────────────────────────────────────────

def apply_rules_to_transaction(tx, rules):
    text_map = {
        'description': (tx.get('description') or '').lower(),
        'counterpart':  (tx.get('counterpart') or '').lower(),
        'iban':         (tx.get('iban') or '').lower(),
    }
    for rule in sorted(rules, key=lambda r: -r['priority']):
        field_val  = text_map.get(rule['field'], '')
        pattern    = rule['pattern'].lower()
        match_type = rule['match_type']
        matched = False
        if match_type == 'contains':
            matched = pattern in field_val
        elif match_type == 'starts_with':
            matched = field_val.startswith(pattern)
        elif match_type == 'ends_with':
            matched = field_val.endswith(pattern)
        elif match_type == 'exact':
            matched = field_val == pattern
        elif match_type == 'regex':
            try:
                matched = bool(re.search(pattern, field_val))
            except re.error:
                pass
        if matched:
            return rule['category'], rule['subcategory']
    return None, None

def apply_rules_to_uncategorized(conn):
    """Apply rules only to transactions that have no category and were not manually set."""
    rules = [dict(r) for r in conn.execute("SELECT * FROM rules ORDER BY priority DESC").fetchall()]
    uncategorized = conn.execute(
        "SELECT * FROM transactions WHERE (category IS NULL OR category = '') AND manual = 0"
    ).fetchall()
    updated = 0
    for tx in uncategorized:
        cat, subcat = apply_rules_to_transaction(dict(tx), rules)
        if cat:
            conn.execute(
                "UPDATE transactions SET category=?, subcategory=? WHERE id=?",
                (cat, subcat or '', tx['id'])
            )
            updated += 1
    conn.commit()
    return {'updated': updated, 'total_uncategorized': len(uncategorized)}

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    return render_template('index.html')

def load_categories_from_db(conn):
    """Return {name: [subcats]} and {name: color} from DB."""
    try:
        cats = conn.execute("SELECT * FROM categories ORDER BY sort_order, name").fetchall()
        categories = {}
        colors = {}
        for cat in cats:
            subs = conn.execute(
                "SELECT name FROM subcategories WHERE category_id=? ORDER BY sort_order, name",
                (cat['id'],)
            ).fetchall()
            categories[cat['name']] = [s['name'] for s in subs]
            colors[cat['name']] = cat['color']
        return categories, colors
    except Exception:
        return {}, {}

@app.route('/api/categories')
def get_categories():
    conn = get_db()
    categories, colors = load_categories_from_db(conn)
    conn.close()
    return jsonify({'categories': categories, 'colors': colors})

@app.route('/api/categories', methods=['POST'])
def create_category():
    data = request.json
    name  = (data.get('name') or '').strip()
    color = data.get('color') or '#888888'
    if not name:
        return jsonify({'error': 'Naam is verplicht'}), 400
    conn = get_db()
    try:
        order = conn.execute("SELECT COALESCE(MAX(sort_order),0)+1 FROM categories").fetchone()[0]
        cur = conn.execute("INSERT INTO categories (name, color, sort_order) VALUES (?,?,?)", (name, color, order))
        conn.commit()
        return jsonify({'id': cur.lastrowid, 'ok': True})
    except sqlite3.IntegrityError:
        return jsonify({'error': 'Categorie bestaat al'}), 400
    finally:
        conn.close()

@app.route('/api/categories/<int:cat_id>', methods=['PUT'])
def update_category(cat_id):
    data = request.json
    name  = (data.get('name') or '').strip()
    color = data.get('color') or '#888888'
    if not name:
        return jsonify({'error': 'Naam is verplicht'}), 400
    conn = get_db()
    old = conn.execute("SELECT name FROM categories WHERE id=?", (cat_id,)).fetchone()
    if not old:
        conn.close(); return jsonify({'error': 'Niet gevonden'}), 404
    # Also rename in transactions and rules
    conn.execute("UPDATE categories SET name=?, color=? WHERE id=?", (name, color, cat_id))
    conn.execute("UPDATE transactions SET category=? WHERE category=?", (name, old['name']))
    conn.execute("UPDATE rules SET category=? WHERE category=?", (name, old['name']))
    conn.commit(); conn.close()
    return jsonify({'ok': True})

@app.route('/api/categories/<int:cat_id>', methods=['DELETE'])
def delete_category(cat_id):
    conn = get_db()
    cat = conn.execute("SELECT name FROM categories WHERE id=?", (cat_id,)).fetchone()
    if not cat:
        conn.close(); return jsonify({'error': 'Niet gevonden'}), 404
    conn.execute("DELETE FROM subcategories WHERE category_id=?", (cat_id,))
    conn.execute("DELETE FROM categories WHERE id=?", (cat_id,))
    conn.commit(); conn.close()
    return jsonify({'ok': True})

@app.route('/api/categories/<int:cat_id>/subcategories', methods=['POST'])
def create_subcategory(cat_id):
    data = request.json
    name = (data.get('name') or '').strip()
    if not name:
        return jsonify({'error': 'Naam is verplicht'}), 400
    conn = get_db()
    try:
        order = conn.execute("SELECT COALESCE(MAX(sort_order),0)+1 FROM subcategories WHERE category_id=?", (cat_id,)).fetchone()[0]
        cur = conn.execute("INSERT INTO subcategories (category_id, name, sort_order) VALUES (?,?,?)", (cat_id, name, order))
        conn.commit()
        return jsonify({'id': cur.lastrowid, 'ok': True})
    except sqlite3.IntegrityError:
        return jsonify({'error': 'Subcategorie bestaat al'}), 400
    finally:
        conn.close()

@app.route('/api/subcategories/<int:sub_id>', methods=['PUT'])
def update_subcategory(sub_id):
    data = request.json
    name = (data.get('name') or '').strip()
    if not name:
        return jsonify({'error': 'Naam is verplicht'}), 400
    conn = get_db()
    old = conn.execute(
        "SELECT s.name, c.name as cat_name FROM subcategories s JOIN categories c ON c.id=s.category_id WHERE s.id=?",
        (sub_id,)
    ).fetchone()
    if not old:
        conn.close(); return jsonify({'error': 'Niet gevonden'}), 404
    conn.execute("UPDATE subcategories SET name=? WHERE id=?", (name, sub_id))
    conn.execute("UPDATE transactions SET subcategory=? WHERE category=? AND subcategory=?",
                 (name, old['cat_name'], old['name']))
    conn.execute("UPDATE rules SET subcategory=? WHERE category=? AND subcategory=?",
                 (name, old['cat_name'], old['name']))
    conn.commit(); conn.close()
    return jsonify({'ok': True})

@app.route('/api/subcategories/<int:sub_id>', methods=['DELETE'])
def delete_subcategory(sub_id):
    conn = get_db()
    conn.execute("DELETE FROM subcategories WHERE id=?", (sub_id,))
    conn.commit(); conn.close()
    return jsonify({'ok': True})

@app.route('/api/categories/full')
def get_categories_full():
    """Return full category list with ids for management UI."""
    conn = get_db()
    cats = conn.execute("SELECT * FROM categories ORDER BY sort_order, name").fetchall()
    result = []
    for cat in cats:
        subs = conn.execute(
            "SELECT * FROM subcategories WHERE category_id=? ORDER BY sort_order, name",
            (cat['id'],)
        ).fetchall()
        result.append({**dict(cat), 'subcategories': [dict(s) for s in subs]})
    conn.close()
    return jsonify(result)

@app.route('/api/import/preview', methods=['POST'])
def preview_import():
    """Parse XML and return transaction count + sample without saving."""
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    raw = request.files['file'].read()
    # Count <Ntry> as direct children of <Stmt> — same logic as the parser
    try:
        root = ET.fromstring(raw)
        ntry_count = sum(
            1 for stmt in root.iter() if tag_local(stmt) == 'Stmt'
            for child in stmt if tag_local(child) == 'Ntry'
        )
    except Exception:
        ntry_count = raw.count(b'<Ntry>')  # fallback
    try:
        transactions = parse_camt053(raw)
    except Exception as e:
        return jsonify({'error': str(e)}), 400
    return jsonify({
        'ntry_tags_in_file': ntry_count,
        'parsed':            len(transactions),
        'sample':            transactions[:3],
    })

# Import
@app.route('/api/import', methods=['POST'])
def import_camt():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    f = request.files['file']
    raw = f.read()

    # Step 1: count raw <Ntry> tags in the file bytes — ground truth
    raw_ntry_count = raw.count(b'<Ntry>')
    app.logger.info(f"IMPORT: raw <Ntry> count in file bytes = {raw_ntry_count}")

    # Step 2: parse
    try:
        transactions = parse_camt053(raw)
    except Exception as e:
        import traceback
        app.logger.error(f"IMPORT: parse error: {traceback.format_exc()}")
        return jsonify({'error': f'Parse error: {e}'}), 400

    app.logger.info(f"IMPORT: parser returned {len(transactions)} transactions")

    # Step 3: log every transaction
    for i, tx in enumerate(transactions):
        app.logger.info(f"  TX[{i}]: date={tx['date']} amount={tx['amount']} ref={tx['ref']} counterpart={tx['counterpart']}")

    # Step 4: insert all, log every skip
    conn = get_db()
    rules = [dict(r) for r in conn.execute("SELECT * FROM rules ORDER BY priority DESC").fetchall()]
    inserted = errors = 0
    for i, tx in enumerate(transactions):
        if not tx['date']:
            app.logger.warning(f"  SKIP TX[{i}]: no date — ref={tx['ref']}")
            errors += 1
            continue
        cat, subcat = apply_rules_to_transaction(tx, rules)
        try:
            conn.execute(
                "INSERT INTO transactions (date,amount,description,counterpart,iban,ref,category,subcategory) VALUES (?,?,?,?,?,?,?,?)",
                (tx['date'], tx['amount'], tx['description'], tx['counterpart'], tx['iban'], tx['ref'], cat, subcat)
            )
            inserted += 1
        except Exception as e:
            app.logger.error(f"  ERROR TX[{i}]: {e} — ref={tx['ref']} date={tx['date']} amount={tx['amount']}")

    conn.execute("INSERT INTO imports (filename,imported_at,count) VALUES (?,?,?)",
                 (f.filename, datetime.now().isoformat(), inserted))
    conn.commit()
    conn.close()

    app.logger.info(f"IMPORT: inserted={inserted} errors={errors} raw_ntry={raw_ntry_count} parsed={len(transactions)}")
    return jsonify({
        'imported': inserted,
        'errors': errors,
        'total': len(transactions),
        'raw_ntry_count': raw_ntry_count,
    })

# Transactions
@app.route('/api/transactions')
def get_transactions():
    month  = request.args.get('month')
    cat    = request.args.get('category')
    subcat = request.args.get('subcategory')
    uncat  = request.args.get('uncategorized')
    query, params = "SELECT * FROM transactions WHERE 1=1", []
    if month:
        query += " AND strftime('%Y-%m', date) = ?"; params.append(month)
    if cat:
        query += " AND category = ?"; params.append(cat)
    if subcat:
        query += " AND subcategory = ?"; params.append(subcat)
    if uncat == '1':
        query += " AND (category IS NULL OR category = '')"
    query += " ORDER BY date DESC"
    conn = get_db()
    rows = [dict(r) for r in conn.execute(query, params).fetchall()]
    conn.close()
    return jsonify(rows)

@app.route('/api/transactions/<int:tx_id>', methods=['GET'])
def get_transaction(tx_id):
    conn = get_db()
    row = conn.execute("SELECT * FROM transactions WHERE id=?", (tx_id,)).fetchone()
    conn.close()
    if row is None:
        return jsonify({'error': 'Not found'}), 404
    return jsonify(dict(row))

@app.route('/api/transactions/<int:tx_id>', methods=['PATCH'])
def update_transaction(tx_id):
    data = request.json
    conn = get_db()
    conn.execute(
        "UPDATE transactions SET category=?, subcategory=?, manual=1 WHERE id=?",
        (data.get('category'), data.get('subcategory'), tx_id)
    )
    conn.commit()
    conn.close()
    return jsonify({'ok': True})

@app.route('/api/transactions/<int:tx_id>', methods=['DELETE'])
def delete_transaction(tx_id):
    conn = get_db()
    conn.execute("DELETE FROM transactions WHERE id=?", (tx_id,))
    conn.commit()
    conn.close()
    return jsonify({'ok': True})

# Dashboard
@app.route('/api/dashboard')
def dashboard():
    month = request.args.get('month') or datetime.now().strftime('%Y-%m')
    conn = get_db()
    rows = conn.execute(
        "SELECT category, subcategory, amount FROM transactions WHERE strftime('%Y-%m', date) = ?",
        (month,)
    ).fetchall()
    months = [r[0] for r in conn.execute(
        "SELECT DISTINCT strftime('%Y-%m', date) as m FROM transactions ORDER BY m DESC"
    ).fetchall()]
    uncat_count = conn.execute(
        "SELECT COUNT(*) FROM transactions WHERE (category IS NULL OR category='') AND strftime('%Y-%m',date)=?",
        (month,)
    ).fetchone()[0]
    _, colors = load_categories_from_db(conn)
    conn.close()

    by_category = {}
    by_subcategory = {}
    income_cats = {}
    expense_cats = {}
    total_income = total_expense = 0.0

    for row in rows:
        cat    = row['category']    or 'Niet gecategoriseerd'
        subcat = row['subcategory'] or 'Overig'
        amt    = row['amount']
        by_category[cat] = by_category.get(cat, 0) + amt
        key = f"{cat}::{subcat}"
        by_subcategory[key] = by_subcategory.get(key, 0) + amt
        if cat == 'Inkomsten':
            total_income += amt
            income_cats[cat] = income_cats.get(cat, 0) + amt
        elif cat in ('Sparen', 'Beleggen'):
            if amt >= 0:
                total_income += amt
                income_cats[cat] = income_cats.get(cat, 0) + amt
            else:
                total_expense += amt
                expense_cats[cat] = expense_cats.get(cat, 0) + amt
        else:
            total_expense += amt
            expense_cats[cat] = expense_cats.get(cat, 0) + amt

    return jsonify({
        'month':              month,
        'months':             months,
        'total_income':       round(total_income, 2),
        'total_expense':      round(abs(total_expense), 2),
        'balance':            round(total_income + total_expense, 2),
        'by_category':        {k: round(v, 2) for k, v in by_category.items()},
        'income_categories':  {k: round(v, 2) for k, v in income_cats.items()},
        'expense_categories': {k: round(abs(v), 2) for k, v in expense_cats.items()},
        'by_subcategory':     {k: round(v, 2) for k, v in by_subcategory.items()},
        'uncategorized':      uncat_count,
        'colors':             colors,
    })

# Rules
@app.route('/api/rules', methods=['GET'])
def get_rules():
    conn = get_db()
    rows = [dict(r) for r in conn.execute("SELECT * FROM rules ORDER BY priority DESC, id").fetchall()]
    conn.close()
    return jsonify(rows)

@app.route('/api/rules', methods=['POST'])
def create_rule():
    data = request.json
    conn = get_db()
    c = conn.cursor()
    c.execute(
        "INSERT INTO rules (name,field,match_type,pattern,category,subcategory,priority) VALUES (?,?,?,?,?,?,?)",
        (data.get('name',''), data['field'], data['match_type'],
         data['pattern'], data['category'], data['subcategory'], data.get('priority', 0))
    )
    rule_id = c.lastrowid
    conn.commit()
    apply_rules_to_uncategorized(conn)
    conn.close()
    return jsonify({'id': rule_id, 'ok': True})

@app.route('/api/rules/<int:rule_id>', methods=['PUT'])
def update_rule(rule_id):
    data = request.json
    conn = get_db()
    conn.execute(
        "UPDATE rules SET name=?,field=?,match_type=?,pattern=?,category=?,subcategory=?,priority=? WHERE id=?",
        (data.get('name',''), data['field'], data['match_type'],
         data['pattern'], data['category'], data['subcategory'],
         data.get('priority', 0), rule_id)
    )
    conn.commit()
    apply_rules_to_uncategorized(conn)
    conn.close()
    return jsonify({'ok': True})

@app.route('/api/rules/<int:rule_id>', methods=['DELETE'])
def delete_rule(rule_id):
    conn = get_db()
    conn.execute("DELETE FROM rules WHERE id=?", (rule_id,))
    conn.commit()
    conn.close()
    return jsonify({'ok': True})

@app.route('/api/rules/apply', methods=['POST'])
def apply_rules():
    conn = get_db()
    result = apply_rules_to_uncategorized(conn)
    conn.close()
    return jsonify(result)

@app.route('/api/category-stats')
def category_stats():
    """Return avg/min/max per category and subcategory across all months."""
    conn = get_db()
    # Get all months available
    months = [r[0] for r in conn.execute(
        "SELECT DISTINCT strftime('%Y-%m', date) as m FROM transactions ORDER BY m"
    ).fetchall()]

    if not months:
        conn.close()
        return jsonify({'categories': [], 'months_count': 0})

    # Per month, sum per category
    cat_by_month = {}  # {category: {month: total}}
    rows = conn.execute(
        "SELECT strftime('%Y-%m', date) as m, category, SUM(amount) as total "
        "FROM transactions WHERE category IS NOT NULL AND category != '' "
        "GROUP BY m, category"
    ).fetchall()
    for row in rows:
        cat = row['category']
        m   = row['m']
        if cat not in cat_by_month:
            cat_by_month[cat] = {}
        cat_by_month[cat][m] = row['total']

    # Per month, sum per subcategory
    sub_by_month = {}  # {"cat::sub": {month: total}}
    rows2 = conn.execute(
        "SELECT strftime('%Y-%m', date) as m, category, subcategory, SUM(amount) as total "
        "FROM transactions WHERE category IS NOT NULL AND category != '' "
        "GROUP BY m, category, subcategory"
    ).fetchall()
    for row in rows2:
        key = f"{row['category']}::{row['subcategory'] or 'Overig'}"
        m   = row['m']
        if key not in sub_by_month:
            sub_by_month[key] = {}
        sub_by_month[key][m] = row['total']

    # Load budgets
    budget_rows = conn.execute("SELECT key, amount FROM budgets").fetchall() if _table_exists(conn, 'budgets') else []
    budgets = {r['key']: r['amount'] for r in budget_rows}

    _, colors = load_categories_from_db(conn)
    conn.close()

    def compute_stats(by_month_dict, key, months_list):
        monthly_vals = [abs(by_month_dict[key].get(m, 0)) for m in months_list]
        non_zero = [v for v in monthly_vals if v > 0]
        avg = sum(non_zero) / len(non_zero) if non_zero else 0
        mn  = min(non_zero) if non_zero else 0
        mx  = max(non_zero) if non_zero else 0
        return round(avg, 2), round(mn, 2), round(mx, 2)

    INCOME_CATS  = {'Inkomsten'}
    MIXED_CATS   = {'Sparen', 'Beleggen'}

    result = []
    for cat, monthly in cat_by_month.items():
        avg, mn, mx = compute_stats(cat_by_month, cat, months)
        vals = list(monthly.values())
        if cat in INCOME_CATS:
            is_income = True
        elif cat in MIXED_CATS:
            is_income = False  # show in budget table (expense side)
        else:
            is_income = False
        result.append({
            'key':       cat,
            'category':  cat,
            'subcategory': None,
            'is_income': is_income,
            'avg':  avg,
            'min':  mn,
            'max':  mx,
            'budget': budgets.get(cat),
            'color': colors.get(cat, '#666'),
            'months_present': len([v for v in vals if v != 0]),
        })
        # Subcategories
        for key, sub_monthly in sub_by_month.items():
            if not key.startswith(cat + '::'):
                continue
            subcat = key.split('::', 1)[1]
            s_avg, s_mn, s_mx = compute_stats(sub_by_month, key, months)
            s_vals = list(sub_monthly.values())
            if cat in INCOME_CATS:
                s_income = True
            elif cat in MIXED_CATS:
                s_income = False
            else:
                s_income = False
            result.append({
                'key':        key,
                'category':   cat,
                'subcategory': subcat,
                'is_income':  s_income,
                'avg':   s_avg,
                'min':   s_mn,
                'max':   s_mx,
                'budget': budgets.get(key),
                'color': colors.get(cat, '#666'),
                'months_present': len([v for v in s_vals if v != 0]),
            })

    return jsonify({'stats': result, 'months_count': len(months), 'months': months})


def _table_exists(conn, table):
    return conn.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()[0] > 0


@app.route('/api/budgets', methods=['GET'])
def get_budgets():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS budgets (
            key    TEXT PRIMARY KEY,
            amount REAL NOT NULL
        )
    """)
    rows = [dict(r) for r in conn.execute("SELECT key, amount FROM budgets").fetchall()]
    conn.commit(); conn.close()
    return jsonify(rows)


@app.route('/api/budgets', methods=['POST'])
def save_budget():
    data = request.json  # {key, amount}
    key    = data.get('key', '').strip()
    amount = data.get('amount')
    if not key:
        return jsonify({'error': 'key vereist'}), 400
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS budgets (
            key    TEXT PRIMARY KEY,
            amount REAL NOT NULL
        )
    """)
    if amount is None or amount == '':
        conn.execute("DELETE FROM budgets WHERE key=?", (key,))
    else:
        conn.execute("INSERT OR REPLACE INTO budgets (key, amount) VALUES (?,?)", (key, float(amount)))
    conn.commit(); conn.close()
    return jsonify({'ok': True})


@app.route('/api/months')
def get_months():
    conn = get_db()
    rows = conn.execute(
        "SELECT DISTINCT strftime('%Y-%m', date) as m FROM transactions ORDER BY m DESC"
    ).fetchall()
    conn.close()
    return jsonify([r[0] for r in rows])

INCOME_CATS = {'Inkomsten'}
MIXED_CATS  = {'Sparen', 'Beleggen'}

@app.route('/api/period-comparison')
def period_comparison():
    end_date = request.args.get('end_date')   # YYYY-MM  (inclusive)
    months   = request.args.get('months', '3')
    try:
        months = int(months)
        if months < 1 or months > 24:
            raise ValueError
    except ValueError:
        return jsonify({'error': 'months must be 1-24'}), 400

    conn = get_db()

    # Available months in the DB for populating the selector
    available = [r[0] for r in conn.execute(
        "SELECT DISTINCT strftime('%Y-%m', date) as m FROM transactions ORDER BY m DESC"
    ).fetchall()]

    if not end_date or end_date not in available:
        end_date = available[0] if available else datetime.now().strftime('%Y-%m')

    def month_offset(ym, delta):
        """Add delta months to a YYYY-MM string."""
        y, m = int(ym[:4]), int(ym[5:7])
        m += delta
        while m > 12: m -= 12; y += 1
        while m < 1:  m += 12; y -= 1
        return f"{y:04d}-{m:02d}"

    # Period B: end_date going back `months` months
    end_b   = end_date
    start_b = month_offset(end_date, -(months - 1))

    # Period A: same length, exactly one year earlier
    end_a   = month_offset(end_date, -12)
    start_a = month_offset(start_b,  -12)

    def label(start, end):
        if start == end:
            return start
        return f"{start} – {end}"

    def totals_for_period(start, end):
        rows = conn.execute(
            "SELECT category, SUM(amount) as total FROM transactions "
            "WHERE strftime('%Y-%m', date) BETWEEN ? AND ? GROUP BY category",
            (start, end)
        ).fetchall()
        income = expense = 0.0
        by_cat = {}
        for row in rows:
            cat = row['category'] or 'Niet gecategoriseerd'
            amt = row['total']
            by_cat[cat] = amt
            if cat in INCOME_CATS:
                income += amt
            elif cat in MIXED_CATS:
                if amt >= 0: income  += amt
                else:        expense += amt
            else:
                expense += amt
        return round(income, 2), round(abs(expense), 2), {k: round(v, 2) for k, v in by_cat.items()}

    income_a, expense_a, cats_a = totals_for_period(start_a, end_a)
    income_b, expense_b, cats_b = totals_for_period(start_b, end_b)

    _, colors = load_categories_from_db(conn)
    conn.close()

    all_cats = sorted(set(list(cats_a.keys()) + list(cats_b.keys())))
    categories = []
    for cat in all_cats:
        amt_a   = cats_a.get(cat, 0.0)
        amt_b   = cats_b.get(cat, 0.0)
        amt_ref = amt_a if amt_a != 0 else amt_b
        if cat in INCOME_CATS:
            side = 'income'
        elif cat in MIXED_CATS:
            side = 'income' if amt_ref >= 0 else 'expense'
        else:
            side = 'expense'
            amt_a = abs(amt_a)
            amt_b = abs(amt_b)
        diff = round(amt_b - amt_a, 2)
        pct  = round(diff / amt_a * 100, 1) if amt_a != 0 else None
        categories.append({
            'category': cat,
            'side':     side,
            'period_a': amt_a,
            'period_b': amt_b,
            'diff':     diff,
            'pct':      pct,
            'color':    colors.get(cat, '#666'),
        })

    return jsonify({
        'available':  available,
        'end_date':   end_date,
        'months':     months,
        'label_a':    label(start_a, end_a),
        'label_b':    label(start_b, end_b),
        'income_a':   income_a,
        'income_b':   income_b,
        'expense_a':  expense_a,
        'expense_b':  expense_b,
        'categories': categories,
    })

# ── AI Categorization ─────────────────────────────────────────────────────────

def build_ai_prompt(transactions, categories):
    """Build a prompt asking Gemini to categorize a batch of transactions."""
    cat_list = []
    for cat_name, subcats in categories.items():
        if subcats:
            cat_list.append(f"- {cat_name}: {', '.join(subcats)}")
        else:
            cat_list.append(f"- {cat_name}")

    tx_lines = []
    for tx in transactions:
        tx_lines.append({
            "id": tx["id"],
            "amount": tx["amount"],
            "description": tx["description"] or "",
            "counterpart": tx["counterpart"] or "",
        })

    return f"""Je bent een assistent die Nederlandse banktransacties categoriseert.

Beschikbare categorieën en subcategorieën:
{chr(10).join(cat_list)}

Regels:
- Positieve bedragen zijn inkomsten (gebruik categorie "Inkomsten" of "Sparen"/"Beleggen" indien passend)
- Negatieve bedragen zijn uitgaven
- Kies altijd de meest specifieke subcategorie die past
- Als geen subcategorie past, laat subcategory dan leeg ("")
- Als echt geen categorie past, gebruik "Niet gecategoriseerd"

Transacties om te categoriseren:
{json.dumps(tx_lines, ensure_ascii=False, indent=2)}

Antwoord ALLEEN met een JSON-array in dit exacte formaat, geen uitleg:
[{{"id": 123, "category": "Huishouden", "subcategory": "Boodschappen"}}, ...]"""


@app.route('/api/ai-categorize', methods=['POST'])
def ai_categorize():
    """
    AI-categorisering van ongecategoriseerde transacties via Anthropic API.

    Body (optioneel):
      { "limit": 50, "api_key": "AIza..." }

    De API-sleutel kan ook als omgevingsvariabele GEMINI_API_KEY worden meegegeven.
    """
    data = request.json or {}
    limit = min(int(data.get('limit', 50)), 200)

    api_key = data.get('api_key') or os.environ.get('GEMINI_API_KEY', '')
    if not api_key:
        return jsonify({'error': 'Geen Gemini API-sleutel opgegeven. Geef api_key mee in de request body of stel GEMINI_API_KEY in als omgevingsvariabele.'}), 400

    conn = get_db()

    # Haal ongecategoriseerde transacties op (niet handmatig ingesteld)
    uncategorized = [dict(r) for r in conn.execute(
        "SELECT id, date, amount, description, counterpart, iban FROM transactions "
        "WHERE (category IS NULL OR category = '') AND manual = 0 "
        "ORDER BY date DESC LIMIT ?",
        (limit,)
    ).fetchall()]

    if not uncategorized:
        conn.close()
        return jsonify({'categorized': 0, 'message': 'Geen ongecategoriseerde transacties gevonden.'})

    # Haal categorieën op uit de database
    categories, _ = load_categories_from_db(conn)

    # Stuur naar Gemini in batches van 30 (om context-limiet te respecteren)
    BATCH_SIZE = 30
    total_categorized = 0
    errors = []

    try:
        genai.configure(api_key=api_key)
        model_name = data.get('model', 'gemini-2.5-flash')
        client = genai.GenerativeModel(model_name)
    except Exception as e:
        conn.close()
        return jsonify({'error': f'Kon Gemini client niet aanmaken: {e}'}), 500

    for i in range(0, len(uncategorized), BATCH_SIZE):
        batch = uncategorized[i:i + BATCH_SIZE]
        prompt = build_ai_prompt(batch, categories)

        try:
            response = client.generate_content(prompt)
            raw = response.text.strip()

            # Verwijder eventuele markdown code fences
            raw = re.sub(r'^```[a-z]*\n?', '', raw)
            raw = re.sub(r'\n?```$', '', raw)

            results = json.loads(raw)

            for item in results:
                tx_id = item.get('id')
                cat   = (item.get('category') or '').strip()
                subcat = (item.get('subcategory') or '').strip()

                if not tx_id or not cat:
                    continue

                # Sla op met manual=0 zodat regels later kunnen overschrijven
                conn.execute(
                    "UPDATE transactions SET category=?, subcategory=? WHERE id=? AND manual=0",
                    (cat, subcat, tx_id)
                )
                total_categorized += 1

            conn.commit()

        except json.JSONDecodeError as e:
            errors.append(f'Batch {i//BATCH_SIZE + 1}: kon JSON niet parsen — {e}')
        except Exception as e:
            if 'api' in str(e).lower() or 'quota' in str(e).lower() or 'key' in str(e).lower():
                errors.append(f'Batch {i//BATCH_SIZE + 1}: Gemini API fout — {e}')
            else:
                raise
        except Exception as e:
            errors.append(f'Batch {i//BATCH_SIZE + 1}: onverwachte fout — {e}')

    conn.close()

    return jsonify({
        'categorized': total_categorized,
        'total_uncategorized': len(uncategorized),
        'batches': (len(uncategorized) + BATCH_SIZE - 1) // BATCH_SIZE,
        'errors': errors,
    })



@app.route('/api/ai-models', methods=['POST'])
def list_ai_models():
    """Haal beschikbare Gemini-modellen op voor de opgegeven API-sleutel."""
    data = request.json or {}
    api_key = data.get('api_key') or os.environ.get('GEMINI_API_KEY', '')
    if not api_key:
        return jsonify({'error': 'Geen API-sleutel opgegeven'}), 400
    try:
        genai.configure(api_key=api_key)
        models = [
            m.name for m in genai.list_models()
            if 'generateContent' in m.supported_generation_methods
            and 'gemini' in m.name.lower()
        ]
        models.sort()
        return jsonify({'models': models})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/ai-categorize/status', methods=['GET'])
def ai_categorize_status():
    """Geeft terug hoeveel transacties nog gecategoriseerd moeten worden."""
    conn = get_db()
    total = conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    uncategorized = conn.execute(
        "SELECT COUNT(*) FROM transactions WHERE (category IS NULL OR category = '') AND manual = 0"
    ).fetchone()[0]
    conn.close()
    return jsonify({
        'total': total,
        'uncategorized': uncategorized,
        'categorized': total - uncategorized,
    })


if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=8765, debug=False)
