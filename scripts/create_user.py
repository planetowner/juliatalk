import argparse
import asyncio

from sqlalchemy import select

from app.database import SessionLocal
from app.models import User
from app.passwords import hash_password


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a local JuliaTalk user."
    )
    parser.add_argument("username")
    parser.add_argument("password")
    parser.add_argument("--display-name", required=True)
    parser.add_argument(
        "--language",
        default="ko",
        choices=("ko", "zh-CN"),
    )

    return parser.parse_args()


async def create_user(
    *,
    username: str,
    password: str,
    display_name: str,
    preferred_language: str,
) -> None:
    async with SessionLocal() as session:
        existing_user = await session.scalar(
            select(User).where(User.username == username)
        )

        if existing_user is not None:
            print(
                f"User already exists: {existing_user.username} "
                f"({existing_user.id})"
            )
            return

        user = User(
            username=username,
            display_name=display_name,
            password_hash=hash_password(password),
            preferred_language=preferred_language,
        )

        session.add(user)
        await session.commit()
        await session.refresh(user)

        print(f"Created user: {user.username} ({user.id})")


async def main() -> None:
    args = parse_args()

    await create_user(
        username=args.username,
        password=args.password,
        display_name=args.display_name,
        preferred_language=args.language,
    )


if __name__ == "__main__":
    asyncio.run(main())
