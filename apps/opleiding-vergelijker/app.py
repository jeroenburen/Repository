from flask import Flask, render_template, request, redirect
from flask_sqlalchemy import SQLAlchemy
import os

app = Flask(__name__)

# Database configuratie
db_path = os.path.join(os.getcwd(), 'data', 'studie.db')
if not os.path.exists('data'):
    os.makedirs('data')

app.config['SQLALCHEMY_DATABASE_URI'] = f'sqlite:///{db_path}'
db = SQLAlchemy(app)

# Database Modellen
class Kenmerk(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    naam = db.Column(db.String(100), nullable=False)
    weging = db.Column(db.Integer, nullable=False) # 1 tot 5

class Opleiding(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    naam = db.Column(db.String(100), nullable=False)
    scores = db.relationship('Score', backref='opleiding', cascade="all, delete-orphan")

class Score(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    opleiding_id = db.Column(db.Integer, db.ForeignKey('opleiding.id'), nullable=False)
    kenmerk_id = db.Column(db.Integer, db.ForeignKey('kenmerk.id'), nullable=False)
    waarde = db.Column(db.Integer, nullable=False) # ++=5 tot --=1

# Mapping van symbolen naar getallen
SYMBOL_MAP = {'++': 5, '+': 4, '+-': 3, '-': 2, '--': 1}
INV_SYMBOL_MAP = {v: k for k, v in SYMBOL_MAP.items()}

@app.route('/')
def index():
    kenmerken = Kenmerk.query.all()
    opleidingen = Opleiding.query.all()
    
    resultaten = []
    for o in opleidingen:
        totaal = 0
        onderdelen = []
        for k in kenmerken:
            s = Score.query.filter_by(opleiding_id=o.id, kenmerk_id=k.id).first()
            val = s.waarde if s else 3 # Default naar +- als niet ingevuld
            onderdeel_score = val * k.weging
            totaal += onderdeel_score
            onderdelen.append({'naam': k.naam, 'symbool': INV_SYMBOL_MAP.get(val), 'sub': onderdeel_score})
        
        resultaten.append({'id': o.id, 'naam': o.naam, 'totaal': totaal, 'details': onderdelen})
    
    # Sorteer op totaalscore (hoog naar laag)
    resultaten.sort(key=lambda x: x['totaal'], reverse=True)
    
    return render_template('index.html', kenmerken=kenmerken, resultaten=resultaten)

@app.route('/add_kenmerk', methods=['POST'])
def add_kenmerk():
    naam = request.form.get('naam')
    weging = int(request.form.get('weging'))
    db.session.add(Kenmerk(naam=naam, weging=weging))
    db.session.commit()
    return redirect('/')

@app.route('/add_opleiding', methods=['POST'])
def add_opleiding():
    naam = request.form.get('naam')
    nieuwe_opleiding = Opleiding(naam=naam)
    db.session.add(nieuwe_opleiding)
    db.session.flush() # Haal ID op voor scores
    
    kenmerken = Kenmerk.query.all()
    for k in kenmerken:
        symbool = request.form.get(f'kenmerk_{k.id}')
        waarde = SYMBOL_MAP.get(symbool, 3)
        db.session.add(Score(opleiding_id=nieuwe_opleiding.id, kenmerk_id=k.id, waarde=waarde))
    
    db.session.commit()
    return redirect('/')

@app.route('/delete_kenmerk/<int:id>')
def delete_kenmerk(id):
    kenmerk = Kenmerk.query.get_or_404(id)
    # Verwijder ook handmatig de scores die bij dit kenmerk horen
    Score.query.filter_by(kenmerk_id=id).delete()
    db.session.delete(kenmerk)
    db.session.commit()
    return redirect('/')

@app.route('/update_kenmerk/<int:id>', methods=['POST'])
def update_kenmerk(id):
    kenmerk = Kenmerk.query.get_or_404(id)
    nieuwe_weging = int(request.form.get('weging'))
    kenmerk.weging = nieuwe_weging
    db.session.commit()
    return redirect('/')

@app.route('/delete_opleiding/<int:id>')
def delete_opleiding(id):
    opleiding = Opleiding.query.get_or_404(id)
    db.session.delete(opleiding)
    db.session.commit()
    return redirect('/')

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5100)