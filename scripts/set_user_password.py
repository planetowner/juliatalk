import argparse
import asyncio

from sqlalchemy import select

from app.database import SessionLocal
from app.models import User
from app.passwords import hash_password


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Set a local JuliaTalk user's password."
    )
    parser.add_argument("username")
    parser.add_argument("password")

    return parser.parse_args()


async def set_user_password(
    *,
    username: str,
    password: str,
) -> None:
    async with SessionLocal() as session:
        user = await session.scalar(
            select(User).where(User.username == username)
        )

        if user is None:
            raise SystemExit(f"User not found: {username}")

        user.password_hash = hash_password(password)
        # 관리자 스크립트로 비밀번호를 바꿔도 기존 액세스 토큰을 모두 무효화해요.
        user.token_version += 1

        await session.commit()

        print(f"Updated password for: {user.username} ({user.id})")


async def main() -> None:
    args = parse_args()

    await set_user_password(
        username=args.username,
        password=args.password,
    )


if __name__ == "__main__":
    asyncio.run(main())
