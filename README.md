# JuliaTalk

JuliaTalk is a private two-person chat app with a FastAPI backend and a
Flutter client.

It supports real-time direct messaging between Korean- and Simplified
Chinese-speaking users, with context-aware text translation powered by
DeepSeek.

## Current Features

- Username and password authentication
- Argon2id password hashing
- JWT access tokens
- Token invalidation after password changes
- Editable display names
- Persistent direct conversation history
- Real-time WebSocket message delivery
- Read receipts
- Text, photo, file, voice memo, and call-event messages
- Message replies
- Conversation search
- Text message editing
- Message deletion within the 5-minute unsend window
- Korean to Simplified Chinese text translation
- Simplified Chinese to Korean text translation
- Conversation-context-aware translation
- Original text preserved alongside translated text
- Real-time message, read receipt, edit, delete, and translation updates
- Flutter login and chat client

## Technology Stack

- Python 3.11+
- FastAPI
- SQLAlchemy 2
- PostgreSQL
- asyncpg
- WebSockets
- DeepSeek API through the OpenAI Python client
- PyJWT
- pwdlib with Argon2
- python-dotenv
- Railway deployment configuration
- Flutter / Dart

## Project Structure

```text
app/
  routes/
    auth.py
    messages.py
    users.py
    websocket.py
  database.py
  dependencies.py
  main.py
  models.py
  passwords.py
  schemas.py
  security.py
  translation.py
  websocket_manager.py
scripts/
  create_user.py
  set_user_password.py
mobile/
  lib/
  test/
  pubspec.yaml
railway.toml
requirements.txt
```

## Deployment

The GitHub repository is the source of truth. Push changes to the branch
connected to the hosted backend, then let the deployment platform build and
restart the service.

The backend is configured for Railway in `railway.toml`:

```text
python -m uvicorn app.main:app --host 0.0.0.0 --port $PORT
```

Railway uses `/health` as the health check endpoint.

On startup, the backend creates the required PostgreSQL extensions and tables
if they do not already exist.

## Required Environment Variables

Configure these in the hosted backend environment:

- `DATABASE_URL`: PostgreSQL connection URL
- `JWT_SECRET`: long random signing secret for access tokens
- `DEEPSEEK_API_KEY`: DeepSeek API key
- `DEEPSEEK_BASE_URL`: DeepSeek-compatible API base URL
- `DEEPSEEK_MODEL`: DeepSeek model name

`DATABASE_URL` must point to PostgreSQL. `postgresql://` and `postgres://`
URLs are accepted and normalized to SQLAlchemy's asyncpg driver URL
automatically.

## User Administration

Initial users are not committed to the repository. Create or update users only
from a trusted admin environment that has the hosted backend environment
variables loaded and can reach the production database.

```bash
python -m scripts.create_user julia password123 --display-name "Julia" --language ko
python -m scripts.create_user friend password123 --display-name "Friend" --language zh-CN
```

To change a user's password:

```bash
python -m scripts.set_user_password USERNAME NEW_PASSWORD
```

## Flutter Client Configuration

The Flutter app talks to the deployed backend. Pass the hosted API origin
through `API_BASE_URL`:

```bash
cd mobile
flutter pub get
flutter run --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
```

Use the same `API_BASE_URL` when building release artifacts:

```bash
flutter build apk --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
flutter build ios --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
```

`API_BASE_URL` must be an absolute `http` or `https` URL.

## Tests and Checks

Backend:

```bash
python -m compileall app scripts
```

Flutter:

```bash
cd mobile
flutter analyze
flutter test
```

## Files Excluded From Git

The following files are intentionally excluded from Git:

- `.env`
- `.env.*`
- `.jwt_secret`
- `.venv/`
- Python cache files
- Database dumps
- Editor and operating system files

Production database credentials and dumps may contain user accounts, password
hashes, and private message history, so they must not be uploaded to GitHub.

## Message Translation Flow

1. The original text message is saved immediately.
2. A `message.created` WebSocket event is sent to both users.
3. DeepSeek translates the message in the background.
4. The translated text and translation metadata are saved.
5. A `message.translation.updated` WebSocket event is sent to both users.

If translation fails, the original message remains stored and available.

## Main WebSocket Events

### Connection established

```json
{
  "type": "connected",
  "user": {
    "id": "11111111-1111-4111-8111-111111111111",
    "username": "example",
    "display_name": "Example"
  }
}
```

### Message created

```json
{
  "type": "message.created",
  "message": {
    "id": "33333333-3333-4333-8333-333333333333",
    "translation_status": "pending"
  }
}
```

### Translation updated

```json
{
  "type": "message.translation.updated",
  "message": {
    "id": "33333333-3333-4333-8333-333333333333",
    "translated_content": "Translated message",
    "translation_status": "completed",
    "translation_provider": "deepseek"
  }
}
```

### Messages read

```json
{
  "type": "messages.read",
  "reader_id": "11111111-1111-4111-8111-111111111111",
  "sender_id": "22222222-2222-4222-8222-222222222222",
  "message_ids": ["33333333-3333-4333-8333-333333333333"],
  "read_at": "2026-06-29T12:00:00+00:00"
}
```

### Message updated

```json
{
  "type": "message.updated",
  "message": {
    "id": "33333333-3333-4333-8333-333333333333",
    "content": "Edited text",
    "translation_status": "pending"
  }
}
```

### Message deleted

```json
{
  "type": "message.deleted",
  "message_id": "33333333-3333-4333-8333-333333333333"
}
```

## Important Development Note

The repository does not include database dumps or production user accounts.

The database schema is created automatically when the hosted backend starts
with `DATABASE_URL` configured, but initial users must still be created
separately before login and messaging can be used.

## Project Status

The backend authentication, messaging, read receipts, WebSocket delivery,
bidirectional Korean-Chinese text translation, and Flutter client login/chat
flows are implemented.
