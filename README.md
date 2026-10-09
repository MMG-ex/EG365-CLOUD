# EG365 CLOUD V128

Cloud deployment package for Eğitim Gündem 365.

- n8n 2.34.6
- EG365 Renderer V6
- 1080x1350 image generation
- Catbox public image hosting
- Telegram / Instagram / Threads / Facebook publishing
- Secrets supplied only through environment variables
- Original local V128 is not modified

## Required environment variables

OPENAI_API_KEY
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
TELEGRAM_PUBLIC_URL
INSTAGRAM_USER_ID
INSTAGRAM_ACCESS_TOKEN
THREADS_USER_ID
THREADS_ACCESS_TOKEN
FACEBOOK_PAGE_ID
FACEBOOK_PAGE_ACCESS_TOKEN

Persistent n8n state should use external PostgreSQL.
