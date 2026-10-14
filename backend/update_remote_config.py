import argparse
import json
import os
import sys

def main():
    parser = argparse.ArgumentParser(description="Update remote_config.json safely with UTF-8")
    parser.add_argument("--version-code", type=int, required=True)
    parser.add_argument("--version-name", type=str, required=True)
    parser.add_argument("--apk-url", type=str, required=True)
    parser.add_argument("--changelog", type=str, default="Оновлення радара та бази локацій")
    args = parser.parse_args()

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    target_files = [
        os.path.join(base_dir, "backend", "remote_config.json"),
        os.path.join(base_dir, "remote_config.json")
    ]

    config_data = {
        "version_code": args.version_code,
        "version_name": args.version_name,
        "apk_url": args.apk_url,
        "changelog": args.changelog,
        "extra_locations": {},
        "extra_channels": ["kievn", "kyiv_operativ"],
        "extra_danger_keywords": ["тривога", "пуск", "виліт"],
        "extra_clear_keywords": ["відбій", "чисто"]
    }

    # Merge with existing if present
    primary_file = target_files[0]
    if os.path.exists(primary_file):
        try:
            with open(primary_file, "r", encoding="utf-8") as f:
                existing = json.load(f)
                if isinstance(existing.get("extra_locations"), dict):
                    config_data["extra_locations"] = existing["extra_locations"]
                if isinstance(existing.get("extra_channels"), list):
                    config_data["extra_channels"] = existing["extra_channels"]
                if isinstance(existing.get("extra_danger_keywords"), list):
                    config_data["extra_danger_keywords"] = existing["extra_danger_keywords"]
                if isinstance(existing.get("extra_clear_keywords"), list):
                    config_data["extra_clear_keywords"] = existing["extra_clear_keywords"]
        except Exception as e:
            print(f"Warning reading existing config: {e}", file=sys.stderr)

    for target in target_files:
        try:
            with open(target, "w", encoding="utf-8") as f:
                json.dump(config_data, f, ensure_ascii=False, indent=2)
            print(f"Updated {target}")
        except Exception as e:
            print(f"Error writing {target}: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
