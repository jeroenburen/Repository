# ⚡ Energie Dashboard

Een lokale webapplicatie om je elektriciteitsverbruik, zonnepaneelopwek en kosten bij te houden per maand.

## Vereisten

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)

## Opstarten

```bash
# 1. Pak de map uit en open een terminal in de map energie-dashboard

# 2. Start de applicatie
docker compose up -d --build

# 3. Open je browser en ga naar:
http://localhost:8080
```

De applicatie start automatisch bij elke herstart van Docker.
Om te stoppen: `docker compose down`
Om de applicatie te resetten: `docker compose down -v`
Om de applicatie te bouwen/starten: `docker compose up -d --build`

## Gebruik

### Dashboard
Overzicht van het geselecteerde jaar met:
- Actuele opwek rechtstreeks uit GoodWe inverter
- KPI-kaarten (totaal verbruik, opgewekt, teruggeleverd, kosten)
- Grafieken voor verbruik vs opwek, kosten per maand, teruggeleverd

### Invoer
- Selecteer een jaar bovenaan
- Klik op "+ Invoeren" naast een maand
- Vul verbruik, opgewekt, teruggeleverd en kosten in
- Om een nieuw jaar toe te voegen, klik rechtsboven op het jaar

### Vergelijken
- Selecteer een basisjaar met de jaarknoppen
- Klik op een vergelijkjaar (rood gemarkeerd)
- Zie verschillen in grafieken en percentages

## Data

Je data wordt opgeslagen in een Docker volume (`energie-data`) op je machine.
De data blijft bewaard ook als je de containers herstart.

## Aanpassen

De API-URL staat in `frontend/src/App.jsx` (regel 1):
```
const API = "http://localhost:3001/api";
```

Als je de app op een andere machine draait, pas dit aan naar het IP-adres van die machine.
