[Reading 34 lines from start (total: 34 lines, 0 remaining)]

FROM node:22-bookworm-slim

ENV N8N_VERSION=2.34.6 \
    N8N_PORT=10000 \
    N8N_LISTEN_ADDRESS=0.0.0.0 \
    N8N_PROTOCOL=http \
    N8N_SECURE_COOKIE=false \
    N8N_DIAGNOSTICS_ENABLED=false \
    N8N_VERSION_NOTIFICATIONS_ENABLED=false \
    TZ=Europe/Istanbul \
    GENERIC_TIMEZONE=Europe/Istanbul \
    TEMPLATE_PATH=/opt/renderer/template/ana-sablon.png \
    OUTPUT_DIR=/tmp/eg365-output \
    PUBLIC_BASE_URL=http://127.0.0.1:8787

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv fonts-dejavu-core tini curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g n8n@2.34.6 \
    && mkdir -p /opt/renderer/template /opt/workflow /tmp/eg365-output /home/node/.n8n

COPY renderer/requirements.txt /opt/renderer/requirements.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r /opt/renderer/requirements.txt

COPY renderer/app.py /opt/renderer/app.py
COPY renderer/template/ana-sablon.png /opt/renderer/template/ana-sablon.png
COPY workflow/EG365_CLOUD_RENDER_V128.json /opt/workflow/EG365_CLOUD_RENDER_V128.json
COPY start.sh /opt/start.sh
RUN chmod +x /opt/start.sh

EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/opt/start.sh"]

[executed on device: MMG (e2d9b62d-90f0-404b-99cb-d8f6e744dc7b)]