import os
import asyncio
from telethon import TelegramClient

API_ID = int(os.getenv("TELEGRAM_API_ID", "0"))
API_HASH = os.getenv("TELEGRAM_API_HASH", "")
CHANNEL = "chyste_nebo"

async def main():
    client = TelegramClient('bot_session', API_ID, API_HASH)
    await client.start()
    print("Started")
    msgs = []
    async for message in client.iter_messages(CHANNEL, limit=1000):
        if message.message:
            msgs.append(message.message)
    
    with open('chyste_nebo_dump.txt', 'w', encoding='utf-8') as f:
        for m in reversed(msgs):
            f.write(m + "\n====================\n")
    print(f"Dumped {len(msgs)} messages")

asyncio.run(main())
