# JuliaTalk

JuliaTalk is a private two-person chat application backend built with FastAPI.

It supports real-time messaging between Korean- and Simplified Chinese-speaking users, with automatic context-aware translation powered by DeepSeek.

## Current Features

- Username and password authentication
- Argon2id password hashing
- JWT access tokens
- Token invalidation after password changes
- Editable display names
- Persistent message history
- Real-time WebSocket message delivery
- Read receipts
- Korean to Simplified Chinese translation
- Simplified Chinese to Korean translation
- Conversation-context-aware translation
- Original messages preserved alongside translated messages
- Real-time translation updates through WebSocket events

## Technology Stack

- Python 3.11
- FastAPI
- SQLAlchemy 2
- PostgreSQL
- asyncpg
- WebSockets
- DeepSeek API
- PyJWT
- pwdlib with Argon2
- python-dotenv

## Project Structure

```text
app/
├── routes/
│   ├── auth.py
│   ├── messages.py
│   ├── users.py
│   └── websocket.py
├── database.py
├── dependencies.py
├── main.py
├── models.py
├── schemas.py
├── security.py
├── translation.py
└── websocket_manager.py
```

## Local Setup

### 1. Create a virtual environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

### 2. Install dependencies

```powershell
python -m pip install -r requirements.txt
```

### 3. Create the environment file

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

`DATABASE_URL` is required and must point to a PostgreSQL database. `postgresql://` and `postgres://` URLs are accepted and normalized to SQLAlchemy's asyncpg driver URL automatically.

### 4. Start local PostgreSQL

If PostgreSQL is not installed locally, start the bundled Docker service:

```powershell
docker compose up -d postgres
```

If Docker is not installed either, install PostgreSQL directly:

```powershell
winget source update
winget install -e --id PostgreSQL.PostgreSQL.17
```

After installing PostgreSQL, open a new PowerShell window and create the local
database:

```powershell
createdb -U postgres juliatalk
```

If the PostgreSQL tools are not on `PATH`, use the full Windows path:

```powershell
& "C:\Program Files\PostgreSQL\17\bin\createdb.exe" -U postgres juliatalk
```

The default local database URL from `.env.example` matches this service:

```env
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk
```

### 5. Generate a JWT signing secret

```powershell
python -c "from pathlib import Path; import secrets; Path('.jwt_secret').write_text(secrets.token_urlsafe(48), encoding='utf-8')"
```

### 6. Run the server

```powershell
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

On first startup, the server creates the database tables automatically.

### 7. Create local users

After the server has started once, create local login users from a second
terminal:

```powershell
python -m scripts.create_user USERNAME PASSWORD --display-name "Display Name" --language ko
```

To change a local user's password later:

```powershell
python -m scripts.set_user_password USERNAME NEW_PASSWORD
```

The API documentation is available at:

```text
http://127.0.0.1:8000/docs
```

## Local-Only Files

The following files are intentionally excluded from Git:

- `.env`
- `.env.*`
- `.jwt_secret`
- `.venv/`
- Python cache files

Production database credentials and dumps may contain user accounts, password hashes, and private message history, so they must not be uploaded to GitHub.

## Message Translation Flow

1. The original message is saved immediately.
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

## Important Development Note

The repository does not include database dumps or production user accounts.

On a fresh installation, the database tables are created automatically when the server starts with `DATABASE_URL` configured, but initial users must still be created separately before login and messaging can be used.

## Project Status

The backend authentication, messaging, read receipts, WebSocket delivery, and bidirectional Korean-Chinese translation flows are working locally.

The Flutter client is the next development stage.
