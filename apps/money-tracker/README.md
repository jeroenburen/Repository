# 💰 Money Tracker

A self-hosted personal finance tracker for importing, categorising, and analysing bank transactions. Runs as a Docker container with a SQLite database and a web interface.

## Getting started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/)
- A CAMT.053 export from your bank (supported: ASN Bank, ING, ABN AMRO, Rabobank)
- A [Google AI Studio](https://aistudio.google.com/apikey) API key (optional, for AI-assisted categorisation)

### Installation

1. **Clone the repository**

   ```bash
   git clone https://github.com/your-username/money-tracker.git
   cd money-tracker
   ```

2. **Configure environment variables**

   Create a `.env` file in the project root:

   ```bash
   GEMINI_API_KEY=AIzaSy...   # Optional — only needed for AI categorisation
   ```

3. **Build and start the container**

   ```bash
   docker compose up --build -d
   ```

4. **Open the app**

   Navigate to [http://localhost:8282](http://localhost:8282) in your browser.

### Updating

To apply changes after pulling a new version:

```bash
docker compose down && docker compose up --build -d
```

Your data is stored in a named Docker volume (`money-tracker-data`) and is preserved across rebuilds.

### Stopping

```bash
docker compose down
```