#!/bin/sh
set -e
mkdir -p /data
python -c "from app import init_db; init_db()"
exec gunicorn --bind 0.0.0.0:8765 --workers 2 --timeout 300 app:app
