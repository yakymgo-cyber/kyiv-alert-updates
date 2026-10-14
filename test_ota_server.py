"""
Interactive OTA (Over-The-Air) Update Test Server
Launches local backend server and simulates a pending update for connected phones.
"""
import os
import sys
import json
import socket
import uvicorn

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # doesn't even have to be reachable
        s.connect(('8.8.8.8', 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')

    base_dir = os.path.dirname(os.path.abspath(__file__))
    local_ip = get_local_ip()
    port = 8000

    backend_config = os.path.join(base_dir, "backend", "remote_config.json")
    root_config = os.path.join(base_dir, "remote_config.json")
    apk_path = os.path.join(base_dir, "KyivAlert_Phone.apk")

    if not os.path.exists(apk_path):
        print(f"❌ Не знайдено APK файл за шляхом: {apk_path}")
        return

    # Read current config to restore later
    with open(backend_config, "r", encoding="utf-8") as f:
        original_config = json.load(f)

    test_version_code = original_config.get("version_code", 6) + 1
    test_version_name = "1.2.4-OTA"
    test_apk_url = f"http://{local_ip}:{port}/api/download-apk"
    test_changelog = "🚀 Тестове оновлення через повітря (OTA)! Тисніть 'Оновити' для встановлення."

    test_config = dict(original_config)
    test_config["version_code"] = test_version_code
    test_config["version_name"] = test_version_name
    test_config["apk_url"] = test_apk_url
    test_config["changelog"] = test_changelog

    # Write test config
    for p in [backend_config, root_config]:
        with open(p, "w", encoding="utf-8") as f:
            json.dump(test_config, f, ensure_ascii=False, indent=2)

    print("=" * 65)
    print("📡 СЕРВЕР ТЕСТУВАННЯ ВІДДАЛЕНОГО ОНОВЛЕННЯ ЧЕРЕЗ ПОВІТРЯ (OTA)")
    print("=" * 65)
    print(f"🔹 IP комп'ютера у Wi-Fi мережі: {local_ip}:{port}")
    print(f"🔹 Тестова версія для оновлення: v{test_version_name} (Build {test_version_code})")
    print(f"🔹 Посилання на завантаження APK: {test_apk_url}")
    print(f"🔹 Розмір тестового APK: {round(os.path.getsize(apk_path) / 1024 / 1024, 1)} MB")
    print("-" * 65)
    print("📱 ІНСТРУКЦІЯ ДЛЯ ТЕСТУВАННЯ:")
    print(" 1. Переконайтеся, що телефон підключено до тієї ж Wi-Fi мережі, що й ПК.")
    print(" 2. Відкрийте додаток Kyiv Alert на телефоні.")
    print(" 3. Додаток автоматично опитає сервер і покаже фіолетовий банер:")
    print("    '🚀 Доступне оновлення v1.2.4-OTA' з кнопкою 'Оновити'.")
    print(" 4. Натисніть 'Оновити' — почнеться завантаження APK з відображенням %")
    print(" 5. Після завантаження Android автоматично відкриє вікно інсталятора.")
    print("-" * 65)
    print("Для зупинки сервера та повернення вихідного конфігу натисніть CTRL+C.\n")

    sys.path.insert(0, os.path.join(base_dir, "backend"))
    try:
        uvicorn.run("main:app", host="0.0.0.0", port=port, log_level="info")
    except KeyboardInterrupt:
        print("\nЗупинка тестового сервера...")
    finally:
        # Restore original config
        for p in [backend_config, root_config]:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(original_config, f, ensure_ascii=False, indent=2)
        print("✅ Початкову конфігурацію успішно відновлено.")

if __name__ == "__main__":
    main()
