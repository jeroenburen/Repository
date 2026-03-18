# ETF Portefeuille Tracker

Een Docker applicatie voor het bijhouden van je ETF portefeuille.

## Functies

- **CSV Import** – Importeer je broker CSV (Product, Symbool/ISIN, Aantal, Slotkoers, Lokale waarde, Waarde in EUR)
- **Allocatie overzicht** – Zie huidig percentage per ETF, stel doelgewichten in, kleurcodering toont afwijking
- **Stortingen** – Registreer maandelijkse stortingen per jaar met gewogen inleg berekening
- **Vermogensverloop** – Grafiek van je totale vermogen over tijd (gebouwd uit opeenvolgende CSV imports)

## Starten

### Vereisten
- Docker Desktop of Docker Engine + Compose v2

### Opstarten

```bash
# Clone of unzip de applicatie
cd etf-tracker

# Start de containers
docker compose up -d

# Open de browser
open http://localhost:8181
```

### Stoppen

```bash
docker compose down
```

### Data bewaren bij updates

Data wordt opgeslagen in een Docker volume (`etf-data`). Bij `docker compose down` blijft de data bewaard.
Om data te verwijderen: `docker compose down -v`

## Gebruik

### Dashboard
1. Sleep je CSV bestand naar de upload zone of klik om te bladeren
2. Posities worden getoond met huidig percentage
3. Vul bij elke positie een doelpercentage in — kleur geeft afwijking aan:
   - 🟢 Groen: < 2% afwijking
   - 🟡 Geel: 2–5% afwijking  
   - 🟠 Oranje: 5–10% afwijking
   - 🔴 Rood: > 10% afwijking

### Stortingen
- Voeg stortingen toe per datum
- Weging wordt automatisch berekend (1 jan = 1.0, 31 dec ≈ 0.003)
- Schakel tussen jaren via de jaarkeuzelijst

### Verloop
- Elke CSV import voegt een datapunt toe aan de grafiek
- Importeer regelmatig om een mooi verloop te zien

## CSV Formaat

Het verwachte formaat is:
```
Product,Symbool/ISIN,Aantal,Slotkoers,Lokale waarde,,Waarde in EUR
VWRL,IE00B3RBWM25,100,105.23,,10523.00
```

## Poorten

| Service  | Poort |
|----------|-------|
| Frontend | 8181  |
| Backend  | 5050  |
