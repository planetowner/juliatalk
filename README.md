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
- Docker Compose for local PostgreSQL
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
.env.example
docker-compose.yml
requirements.txt
```

## Local Setup

### 1. Clone the project

```bash
git clone https://github.com/planetowner/juliatalk.git
cd juliatalk
```

### 2. Create a Python virtual environment

macOS / Linux:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Windows PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

### 3. Install backend dependencies

macOS / Linux:

```bash
python -m pip install -r requirements.txt
```

Windows PowerShell:

```powershell
python -m pip install -r requirements.txt
```

### 4. Create the environment file

macOS / Linux:

```bash
cp .env.example .env
```

Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Open `.env` and add a valid DeepSeek API key.

Example:

```env
DEEPSEEK_API_KEY=your_api_key_here
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-v4-pro
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk
```

`DATABASE_URL` is required and must point to a PostgreSQL database.
`postgresql://` and `postgres://` URLs are accepted and normalized to
SQLAlchemy's asyncpg driver URL automatically.

### 5. Start local PostgreSQL

The repository includes a Docker Compose service for local PostgreSQL:

```bash
docker compose up -d postgres
```

It starts PostgreSQL 16 with this database URL:

```env
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk
```

If you prefer a PostgreSQL installation outside Docker, create a database named
`juliatalk` and update `DATABASE_URL` in `.env` to match your local credentials.

### 6. Generate a JWT signing secret

The backend can read `JWT_SECRET` from the environment, but local development
usually uses a `.jwt_secret` file:

```bash
python -c "from pathlib import Path; import secrets; Path('.jwt_secret').write_text(secrets.token_urlsafe(48), encoding='utf-8')"
```

### 7. Run the backend

```bash
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

On first startup, the server creates the database extensions and tables
automatically.

The API documentation is available at:

```text
http://127.0.0.1:8000/docs
```

### 8. Create local users

After the backend has started once, create local login users from a second
terminal:

```bash
python -m scripts.create_user julia password123 --display-name "Julia" --language ko
python -m scripts.create_user friend password123 --display-name "Friend" --language zh-CN
```

To change a local user's password later:

```bash
python -m scripts.set_user_password USERNAME NEW_PASSWORD
```

### 9. Run the Flutter client

Install Flutter dependencies from the mobile app directory:

```bash
cd mobile
flutter pub get
```

iOS simulator or Chrome on the same machine:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Android emulator:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Physical phone on the same Wi-Fi:

Run the backend from the repository root:

```bash
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Then run Flutter from `mobile/`:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:8000
```

Make sure your computer firewall allows the phone to reach port `8000`.

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

## Local-Only Files

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

On a fresh installation, the database extensions and tables are created
automatically when the backend starts with `DATABASE_URL` configured, but
initial users must still be created separately before login and messaging can
be used.

## Project Status

The backend authentication, messaging, read receipts, WebSocket delivery,
bidirectional Korean-Chinese text translation, and Flutter client login/chat
flows are implemented for local development.
