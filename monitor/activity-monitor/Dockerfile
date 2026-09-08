# activity-monitor — "is anyone using the system right now?"
#
# Aggregates the two stacks that have no Plex/Tautulli visibility:
#   - BookOrbit readers  (from bookorbit-postgres; BookOrbit has no API for this)
#   - RomM players       (from RomM's own /api/activity)
#
# pg8000 is a PURE-PYTHON postgres driver on purpose: psycopg needs libpq +
# build tooling, which would turn this into a compiled image for one SELECT.
FROM python:3.14-alpine

RUN pip install --no-cache-dir "pg8000==1.31.5"

COPY app.py /app/app.py

WORKDIR /app
EXPOSE 8788
CMD ["python", "-u", "/app/app.py"]
