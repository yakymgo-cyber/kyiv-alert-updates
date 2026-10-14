# -*- coding: utf-8 -*-
"""
Kyiv & Kyiv Oblast Locations Quality and Coverage Auditor
Audits:
1. All entries in _kBaseKyivLocations from main.dart
2. All entries in remote_config.json
3. Coordinate validity (within Kyiv bounds 49.1-51.7 lat, 29.2-32.3 lon)
4. Key conflicts, overlaps, and short key hazards (< 4 chars)
5. Live Telegram scraping of 5 channels to discover unmapped Kyiv locations
"""

import os
import re
import sys
import json
import time
import urllib.request
import urllib.parse
from html.parser import HTMLParser
from collections import Counter, defaultdict

if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAIN_DART_PATH = os.path.join(PROJECT_ROOT, "frontend", "lib", "main.dart")
REMOTE_CONFIG_PATH = os.path.join(PROJECT_ROOT, "remote_config.json")

# 1. Parse _kBaseKyivLocations from main.dart
def parse_main_dart_locations():
    with open(MAIN_DART_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Extract _kExternalBorderKeys
    border_keys_match = re.search(r'const Set<String> _kExternalBorderKeys = \{([\s\S]*?)\};', content)
    external_border_keys = set()
    if border_keys_match:
        for m in re.finditer(r"'([^']+)'", border_keys_match.group(1)):
            external_border_keys.add(m.group(1).lower().strip())

    # Extract _kFarRegions
    far_regions_match = re.search(r'const Set<String> _kFarRegions = \{([\s\S]*?)\};', content)
    far_regions = set()
    if far_regions_match:
        for m in re.finditer(r"'([^']+)'", far_regions_match.group(1)):
            far_regions.add(m.group(1).lower().strip())

    # Extract _kBaseKyivLocations
    locs_match = re.search(r'const _kBaseKyivLocations = <String, \(double, double, String\)>\s*\{([\s\S]*?)\n\};', content)
    locations = {}
    if locs_match:
        body = locs_match.group(1)
        for line in body.splitlines():
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            m = re.match(r"'([^']+)':\s*\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*'([^']+)'\s*\)", line)
            if m:
                key = m.group(1).lower().strip()
                lat = float(m.group(2))
                lon = float(m.group(3))
                name = m.group(4).strip()
                locations[key] = (lat, lon, name)

    return locations, external_border_keys, far_regions

# 2. Parse remote_config.json
def parse_remote_config_locations():
    if not os.path.exists(REMOTE_CONFIG_PATH):
        return {}
    with open(REMOTE_CONFIG_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    extra = data.get("extra_locations", {})
    res = {}
    for k, v in extra.items():
        if isinstance(v, dict) and "lat" in v and "lon" in v:
            res[k.lower().strip()] = (float(v["lat"]), float(v["lon"]), v.get("name", k))
    return res

# 3. Nominatim geocoder
def nominatim_lookup(name: str):
    query = f"{name}, Київська область"
    params = urllib.parse.urlencode({
        "format": "json",
        "q": query,
        "viewbox": "29.2,51.6,32.2,49.1",
        "bounded": "1",
        "limit": "1",
        "accept-language": "uk"
    })
    url = f"https://nominatim.openstreetmap.org/search?{params}"
    headers = {
        "User-Agent": "ua.kyiv.alert.monitor.audit/1.0 (contact: support@kyivalert.ua)",
        "Accept-Language": "uk-UA,uk;q=0.9"
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            if data and len(data) > 0:
                item = data[0]
                lat = float(item["lat"])
                lon = float(item["lon"])
                if 49.1 <= lat <= 51.65 and 29.2 <= lon <= 32.25:
                    disp_name = item.get("display_name", name).split(",")[0].strip() or name
                    return lat, lon, disp_name
    except Exception as e:
        pass
    return None

# 4. Scrape Telegram messages
class TelegramScraper(HTMLParser):
    def __init__(self):
        super().__init__()
        self.messages = []
        self._in_text = False
        self._depth = 0
        self._buf = []

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        cls = attr_dict.get('class', '')
        if tag == 'div' and 'tgme_widget_message_text' in cls:
            self._in_text = True
            self._depth = 0
            self._buf = []
        if self._in_text:
            self._depth += 1
            if tag == 'br':
                self._buf.append('\n')

    def handle_endtag(self, tag):
        if self._in_text:
            self._depth -= 1
            if self._depth <= 0:
                self._in_text = False
                txt = ''.join(self._buf).strip()
                if txt:
                    self.messages.append(txt)
                self._buf = []

    def handle_data(self, data):
        if self._in_text:
            self._buf.append(data)

def fetch_channel_messages(channel: str, max_msgs: int = 50):
    url = f"https://t.me/s/{channel}"
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Linux; Android 14)'})
    try:
        with urllib.request.urlopen(req, timeout=6) as resp:
            html = resp.read().decode('utf-8', errors='replace')
            parser = TelegramScraper()
            parser.feed(html)
            return parser.messages[-max_msgs:]
    except Exception as e:
        print(f"Error fetching channel {channel}: {e}")
        return []

def main():
    print("=" * 70)
    print("KYIV & KYIV OBLAST LOCATIONS AUDIT & VERIFICATION")
    print("=" * 70)

    base_locs, border_keys, far_regions = parse_main_dart_locations()
    extra_locs = parse_remote_config_locations()
    all_locs = {**base_locs, **extra_locs}

    print(f"Total location entries loaded: {len(all_locs)} (Base: {len(base_locs)}, Extra: {len(extra_locs)})")
    print(f"External border keys: {len(border_keys)}")
    print(f"Far regions: {len(far_regions)}")

    # 1. Coordinate range analysis
    kyiv_internal_locs = {}
    external_locs = {}
    outliers = []
    suspicious_coords = []

    for key, (lat, lon, name) in all_locs.items():
        is_external = (key in border_keys or key in far_regions or
                       "пуск" in name.lower() or "р-н" in name.lower() and ("чернігів" in name.lower() or "житомир" in name.lower()))
        if is_external:
            external_locs[key] = (lat, lon, name)
        else:
            kyiv_internal_locs[key] = (lat, lon, name)
            # Check Kyiv bounds: lat 49.1 .. 51.65, lon 29.1 .. 32.3
            if not (49.1 <= lat <= 51.7 and 29.1 <= lon <= 32.3):
                outliers.append((key, lat, lon, name, "Out of Kyiv Oblast bounds"))
            # Check reversed coordinates
            if lat < 35.0 and lon > 45.0:
                suspicious_coords.append((key, lat, lon, name, "Possibility of reversed Lat/Lon"))

    print(f"\nInternal Kyiv Oblast / City locations: {len(kyiv_internal_locs)}")
    print(f"External / Border / Transit locations: {len(external_locs)}")

    if outliers:
        print(f"\n⚠️  OUTLIER LOCATIONS ({len(outliers)}):")
        for k, lat, lon, name, reason in outliers:
            print(f"   - '{k}': ({lat}, {lon}) '{name}' -> {reason}")
    else:
        print("✅ No internal location coordinate outliers found.")

    # 2. Key quality analysis (short keys < 4 chars)
    short_keys = []
    safe_short_keys = {'вднг', 'дврз', 'чзв', 'кпі', 'гора', 'море', 'гатне', 'хотів', 'димер', 'буча', 'ржищів', 'узин'}
    for k in all_locs:
        if len(k) < 4:
            short_keys.append(k)

    print(f"\nShort keys (< 4 characters): {len(short_keys)}")
    for k in short_keys:
        loc = all_locs[k]
        print(f"   - '{k}': -> '{loc[2]}' ({loc[0]}, {loc[1]})")

    # 3. Duplicate coordinate check
    coord_map = defaultdict(list)
    for k, (lat, lon, name) in all_locs.items():
        coord_key = (round(lat, 3), round(lon, 3))
        coord_map[coord_key].append((k, name))

    synonyms_count = 0
    synonyms_groups = []
    for coord, keys in coord_map.items():
        if len(keys) > 1:
            synonyms_count += 1
            names = set(k[1] for k in keys)
            synonyms_groups.append((coord, keys, names))

    print(f"\nLocations sharing identical coordinates (Synonyms/Aliases): {synonyms_count} groups")
    for coord, keys, names in synonyms_groups[:10]:
        key_list = ", ".join([f"'{k[0]}'" for k in keys])
        print(f"   - At {coord}: {key_list} -> {list(names)}")

    # 4. Live Telegram Channel Check
    channels = ["kyiv_airdef", "kievn", "war_monitor", "SK_DM_SK", "air_alert_ua"]
    print("\n" + "=" * 70)
    print("SCRAPING LIVE TELEGRAM CHANNELS & EXTRACTING LOCATIONS")
    print("=" * 70)

    all_messages = []
    for ch in channels:
        msgs = fetch_channel_messages(ch, 40)
        print(f"Channel @{ch}: fetched {len(msgs)} messages")
        all_messages.extend([(ch, m) for m in msgs])

    # Extract location candidates
    # Pattern: words capitalized after prepositions (на, через, біля, поблизу, повз, від, курс, вектор)
    candidate_regex = re.compile(
        r'(?:на|через|біля|поблизу|район[іу]?|повз|від|з|із|в бік|у бік|курсом на|вектор на)\s+([А-ЯІЇЄҐ][а-яіїєґ\x27ʼ\-]{3,})'
    )

    found_in_dict = Counter()
    unmapped_candidates = Counter()
    stop_words = {
        'київщина', 'київська', 'київ', 'увага', 'тривога', 'шахед', 'шахеди', 'шахеда',
        'ракета', 'ракети', 'балістика', 'північ', 'південь', 'захід', 'схід',
        'дніпро', 'україна', 'область', 'області', 'район', 'району', 'сектор',
        'напрямок', 'напрямку', 'вектор', 'курс', 'пуски', 'виходи', 'збиття',
        'відбій', 'чисто', 'повітряна', 'небезпека', 'група', 'групи', 'ціль', 'цілі',
        'областях', 'столиця', 'столиці', 'робота', 'роботу'
    }

    for ch, msg in all_messages:
        # Check against dictionary keys
        msg_lower = msg.lower()
        for k in all_locs:
            if k in msg_lower:
                found_in_dict[all_locs[k][2]] += 1

        for match in candidate_regex.finditer(msg):
            word = match.group(1).strip()
            word_lower = word.lower()
            if word_lower in stop_words or len(word) < 4:
                continue

            # Check if covered by any key
            is_covered = any(k in word_lower for k in all_locs)
            if not is_covered:
                unmapped_candidates[word] += 1

    print("\nMost actively mentioned known locations in live Telegram feeds:")
    for loc_name, count in found_in_dict.most_common(15):
        print(f"   🎯 {loc_name}: {count} mentions")

    print(f"\nUnmapped location candidates found in live channels: {len(unmapped_candidates)}")
    new_candidates_geocoded = []
    for cand, count in unmapped_candidates.most_common(12):
        print(f"   🔎 Checking '{cand}' (mentioned {count} times)...")
        geo = nominatim_lookup(cand)
        time.sleep(1.0) # rate limit 1 req/sec
        if geo:
            lat, lon, disp = geo
            print(f"      📍 MATCH in Kyiv Oblast! {cand} -> ({lat}, {lon}) '{disp}'")
            new_candidates_geocoded.append((cand, lat, lon, disp, count))
        else:
            print(f"      ❌ Not a Kyiv Oblast location (or outside bounds)")

    # 5. Summary & Report
    output_report = {
        "total_locations": len(all_locs),
        "internal_kyiv_locations": len(kyiv_internal_locs),
        "external_locations": len(external_locs),
        "outliers_found": len(outliers),
        "short_keys_count": len(short_keys),
        "active_live_locations": dict(found_in_dict.most_common(20)),
        "unmapped_candidates": dict(unmapped_candidates.most_common(10)),
        "geocoded_new_locations": new_candidates_geocoded
    }

    report_path = os.path.join(PROJECT_ROOT, "frontend", "scratch", "locations_audit_result.json")
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(output_report, f, ensure_ascii=False, indent=2)

    print("\n" + "=" * 70)
    print(f"AUDIT COMPLETE. Report saved to: {report_path}")
    print("=" * 70)

if __name__ == "__main__":
    main()
