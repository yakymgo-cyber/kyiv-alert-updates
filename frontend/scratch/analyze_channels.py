"""
Telegram Channel Message Analyzer
Fetches recent messages from public Telegram channels via t.me/s/ web preview
and analyzes patterns for threat directions, quantities, locations, emojis, etc.
"""

import os
import re
import json
import time
import urllib.request
import urllib.error
import urllib.parse
import sys
from html.parser import HTMLParser
from collections import Counter, defaultdict
from datetime import datetime

if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

# ── Paths ───────────────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(__file__)
REMOTE_CONFIG_PATH = os.path.abspath(os.path.join(BASE_DIR, "..", "..", "backend", "remote_config.json"))
DUMP_PATH = os.path.abspath(os.path.join(BASE_DIR, "..", "..", "backend", "chyste_nebo_dump.txt"))

def stem_location(word: str) -> str:
    lower = word.lower()
    vowels = {'а', 'я', 'у', 'ю', 'і', 'и', 'о', 'е'}
    if len(lower) >= 6 and lower[-1] in vowels:
        lower = lower[:-1]
    return lower

def geocode_candidate(candidate: str):
    """Query Nominatim with bounding box for Kyiv Oblast."""
    query = f"{candidate}, Київська область"
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
        "User-Agent": "ua.kyiv.alert.monitor/1.0 (contact: admin@kyivalert.ua)",
        "Accept-Language": "uk-UA,uk;q=0.9"
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            if data and isinstance(data, list) and len(data) > 0:
                item = data[0]
                lat = float(item["lat"])
                lon = float(item["lon"])
                if 49.1 <= lat <= 51.6 and 29.2 <= lon <= 32.2:
                    disp_name = item.get("display_name", candidate).split(",")[0].strip() or candidate
                    return lat, lon, disp_name
    except Exception as e:
        print(f"      [Geocode error for {candidate}]: {e}")
    return None

def update_remote_config_with_locations(new_locations: dict):
    if not os.path.exists(REMOTE_CONFIG_PATH):
        print(f"⚠️ remote_config.json not found at {REMOTE_CONFIG_PATH}")
        return
    try:
        with open(REMOTE_CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        if "extra_locations" not in cfg:
            cfg["extra_locations"] = {}
        added = 0
        for stem, loc_info in new_locations.items():
            if stem not in cfg["extra_locations"]:
                cfg["extra_locations"][stem] = {
                    "lat": round(loc_info["lat"], 5),
                    "lon": round(loc_info["lon"], 5),
                    "name": loc_info["name"]
                }
                added += 1
                print(f"   [+ Added to remote_config]: {stem} -> {loc_info['name']} ({loc_info['lat']}, {loc_info['lon']})")
        with open(REMOTE_CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        print(f"✅ Successfully updated {REMOTE_CONFIG_PATH} (+{added} locations, total {len(cfg['extra_locations'])})")
    except Exception as e:
        print(f"⚠️ Error updating remote_config.json: {e}")

# ── Channels to scrape ──────────────────────────────────────────────────────
CHANNELS = [
    "kyiv_airdef",
    "kievn",
    "war_monitor",
    "SK_DM_SK",
    "air_alert_ua",
]

# ── Current location dictionary keys (from main.dart) ───────────────────────
KNOWN_LOCATION_KEYS = {
    'київ', 'центр', 'голосіїв', 'теремк', 'деміїв', 'вднг', 'феофані',
    'пирогів', 'пирогов', 'корчуват', 'конча', 'чапаєвк', 'дарниц', 'дврз',
    'рембаз', 'позняк', 'осокорк', 'бортнич', 'вирлиц', 'харківськ',
    'червоний хутір', 'деснян', 'троєщин', 'троя', 'трою', 'лісов', 'биківн',
    'дніпров', 'воскресенк', 'березняк', 'русанівк', 'радужн', 'райдужн',
    'оболон', 'пуща', 'мінськ', 'пріорк', 'куренів', 'печерськ', 'звіринець',
    'теличк', 'поділ', 'подол', 'виноградар', 'святошин', 'білич',
    'новобілич', 'академ', 'борщагів', 'відрадн', "солом'ян", 'солом',
    'жулян', 'шулявк', 'караваєв', "лук'янів", 'лукянів', 'сирец', 'сирц',
    'нивк', 'берковец', 'берківц', 'шевченк', 'татарк', 'видубич',
    'гідропарк', 'труханів', 'васильків', 'васильков', 'васік', 'крушинк',
    'глевах', 'калинівк', 'кобці', 'біла церкв', 'білу церкв', 'білої церкв',
    'узин', 'фастів', 'фастов', 'макарів', 'макаров', 'бородянк', 'ірпін',
    'ірпен', 'буч', 'гостомел', 'чайк', 'стоянк', 'ворзел', 'коцюбинськ',
    'вишнев', 'крюківщин', 'софіївськ', 'петропавлівськ', 'боярк', 'чабан',
    'гатному', 'гатне', 'хотів', 'хотов', 'лісник', 'ходосівк', 'підгірц',
    'козин', 'обухів', 'обухов', 'українк', 'трипілл', 'кагарлик', 'ржищів',
    'миронівк', 'богуслав', 'рокітн', 'рокитн', 'таращ', 'сквир', 'тітіїв',
    'тетіїв', 'переяслав', 'яготин', 'березан', 'баришівк', 'бориспіль',
    'бориспол', 'щаслив', 'проліск', 'гора', 'чубинськ', 'княжич', 'требух',
    'красил', 'гоголів', 'велика димерк', 'димерк', 'калита', 'вороньків',
    'процева', 'проців', 'гнідин', 'вишеньк', 'бровар', 'зазим', 'погреб',
    'пухівк', 'літки', 'вишгород', 'хотянівк', 'новосілк', 'петрівц',
    'лютіж', 'димер', 'іванків', 'іванков', 'фурси', 'вільшанк', 'бакал',
    'володарк', 'дмитрівк', 'петрашівк', 'славутич', 'дзвінков', 'немішаєв',
    'клавдієв', 'пісківк', 'чзв', 'чорнобил', "прип'ят", 'басан', 'згурівк',
    'кіпті', 'козелец', 'остер',
}

# Known display names (for matching found location names against what we know)
KNOWN_DISPLAY_NAMES_LOWER = {
    'київ', 'центр', 'голосіїв', 'теремки', 'деміївка', 'вднг', 'феофанія',
    'пирогів', 'корчувате', 'конча-заспа', 'дарниця', 'дврз', 'рембаза',
    'позняки', 'осокорки', 'бортничі', 'вирлиця', 'харківський масив',
    'червоний хутір', 'деснянський р-н', 'троєщина', 'лісовий масив',
    'биківня', 'дніпровський р-н', 'воскресенка', 'березняки', 'русанівка',
    'райдужний', 'оболонь', 'пуща-водиця', 'мінський масив', 'пріорка',
    'куренівка', 'печерськ', 'звіринець', 'теличка', 'поділ', 'виноградар',
    'святошин', 'біличі', 'новобіличі', 'академмістечко', 'борщагівка',
    'відрадний', "солом'янка", 'жуляни', 'шулявка', 'караваєві дачі',
    "лук'янівка", 'сирець', 'нивки', 'берковець', 'шевченківський р-н',
    'татарка', 'видубичі', 'гідропарк', 'труханів острів', 'васильків',
    'крушинка', 'глеваха', 'калинівка', 'кобці', 'біла церква', 'узин',
    'фастів', 'макарів', 'бородянка', 'ірпінь', 'буча', 'гостомель', 'чайки',
    'стоянка', 'ворзель', 'коцюбинське', 'вишневе', 'крюківщина',
    'софіївська борщагівка', 'петропавлівська борщагівка', 'боярка', 'чабани',
    'гатне', 'хотів', 'лісники', 'ходосівка', 'підгірці', 'козин', 'обухів',
    'українка', 'трипілля', 'кагарлик', 'ржищів', 'миронівка', 'богуслав',
    'рокитне', 'тараща', 'сквира', 'тетіїв', 'переяслав', 'яготин',
    'березань', 'баришівка', 'бориспіль', 'щасливе', 'проліски', 'гора',
    'чубинське', 'княжичі', 'требухів', 'красилівка', 'гоголів',
    'велика димерка', 'калита', 'вороньків', 'проців', 'гнідин', 'вишеньки',
    'бровари', "зазим'я", 'погреби', 'пухівка', 'літки', 'вишгород',
    'хотянівка', 'новосілки', 'нові петрівці', 'лютіж', 'димер', 'іванків',
    'фурси', 'мала вільшанка', 'бакали', 'володарка', 'дмитрівка',
    'петрашівка', 'славутич', 'дзвінкове', 'немішаєве', 'клавдієво-тарасове',
    'пісківка', 'чорнобильська зв', "прип'ять", 'нова басань', 'згурівка',
    'кіпті', 'козелець', 'остер',
}


# ── HTML parser to extract messages from t.me/s/ page ───────────────────────
class TelegramHTMLParser(HTMLParser):
    """Parse t.me/s/CHANNEL HTML to extract message texts."""

    def __init__(self):
        super().__init__()
        self.messages = []
        self._in_message_text = False
        self._current_text_parts = []
        self._depth = 0

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        cls = attr_dict.get('class', '')
        # The message text is in <div class="tgme_widget_message_text ...">
        if tag == 'div' and 'tgme_widget_message_text' in cls:
            self._in_message_text = True
            self._depth = 0
            self._current_text_parts = []
        if self._in_message_text:
            self._depth += 1
            # Convert <br> to newline
            if tag == 'br':
                self._current_text_parts.append('\n')

    def handle_endtag(self, tag):
        if self._in_message_text:
            self._depth -= 1
            if self._depth <= 0:
                self._in_message_text = False
                text = ''.join(self._current_text_parts).strip()
                if text:
                    self.messages.append(text)
                self._current_text_parts = []

    def handle_data(self, data):
        if self._in_message_text:
            self._current_text_parts.append(data)

    def handle_entityref(self, name):
        if self._in_message_text:
            c = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}
            self._current_text_parts.append(c.get(name, f'&{name};'))

    def handle_charref(self, name):
        if self._in_message_text:
            try:
                if name.startswith('x'):
                    ch = chr(int(name[1:], 16))
                else:
                    ch = chr(int(name))
                self._current_text_parts.append(ch)
            except (ValueError, OverflowError):
                self._current_text_parts.append(f'&#{name};')


def fetch_channel_messages(channel_name, max_retries=2):
    """Fetch messages from a Telegram channel's public web preview."""
    url = f"https://t.me/s/{channel_name}"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                       '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept-Language': 'uk-UA,uk;q=0.9,en;q=0.8',
    }

    for attempt in range(max_retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp:
                html = resp.read().decode('utf-8', errors='replace')

            parser = TelegramHTMLParser()
            parser.feed(html)
            return parser.messages
        except urllib.error.HTTPError as e:
            print(f"  [HTTP Error {e.code}] {channel_name} (attempt {attempt+1})")
        except urllib.error.URLError as e:
            print(f"  [URL Error] {channel_name}: {e.reason} (attempt {attempt+1})")
        except Exception as e:
            print(f"  [Error] {channel_name}: {e} (attempt {attempt+1})")

    return []


# ── Pattern definitions ─────────────────────────────────────────────────────

# Direction patterns
DIRECTION_PATTERNS = [
    (r'з\s+півд(?:ня|нів|ен)', 'з півдня/південь'),
    (r'з\s+півноч[іи]', 'з півночі'),
    (r'із?\s+заход[уі]', 'з заходу'),
    (r'із?\s+сход[уі]', 'зі сходу'),
    (r'з\s+напрямку\s+\S+', 'з напрямку ...'),
    (r'(?:з|із|від)\s+(?:бік[уі]|сторони|напрямку)', 'від/з боку/сторони'),
    (r'від\s+\S+', 'від ...'),
    (r'через\s+\S+', 'через ...'),
    (r'у\s+напрямку\s+\S+', 'у напрямку ...'),
    (r'курс(?:ом)?\s+(?:на|до)\s+\S+', 'курсом на/до ...'),
    (r'рух(?:ається|аються)?\s+(?:на|до|у|в)\s+\S+', 'рух на/до/у ...'),
    (r'на\s+(?:Київ|київ|столиц)', 'на Київ/столицю'),
    (r'в\s+бік\s+\S+', 'в бік ...'),
    (r'(?:пн|пд|зх|сх|пн-сх|пн-зх|пд-сх|пд-зх)', 'compass abbreviations'),
]

# Quantity patterns
QUANTITY_PATTERNS = [
    (r'\b(\d+)\s*(?:бпла|дрон|шахед|shaheed|shahed)', 'N дронів/бпла'),
    (r'(?:група|група\s+з)\s*(\d+)', 'група N'),
    (r'(\d+)\s*(?:одиниц|штук|шт\.?)', 'N одиниць/штук'),
    (r'(?:кільк[аі]|декільк[аі]|до)\s+(\d+)', 'кілька/декілька/до N'),
    (r'(\d+)\s*(?:ракет|КР|кр|крилат)', 'N ракет'),
    (r'(\d+)\s*(?:балістич|ТР)', 'N балістичних'),
    (r'близько\s+(\d+)', 'близько N'),
    (r'понад\s+(\d+)', 'понад N'),
    (r'до\s+(\d+)', 'до N'),
    (r'(?:одн[аоеі]|два|дв[іа]|три|чотири|п[\'ʼ]ят|шість|сім|вісім|дев[\'ʼ]ят|десят)\b',
     'word-numbers'),
]

# Threat type patterns (emoji + text)
THREAT_TYPE_EMOJI_PATTERNS = [
    (r'💥', '💥 explosion'),
    (r'🔥', '🔥 fire'),
    (r'🚀', '🚀 rocket/missile'),
    (r'✈️', '✈️ aircraft'),
    (r'🛩', '🛩 aircraft/drone'),
    (r'💣', '💣 bomb'),
    (r'⚡', '⚡ alert/lightning'),
    (r'🟢', '🟢 green/clear'),
    (r'🔴', '🔴 red/danger'),
    (r'🟡', '🟡 yellow/warning'),
    (r'⚠️', '⚠️ warning'),
    (r'🛑', '🛑 stop/danger'),
    (r'❗', '❗ important'),
    (r'‼️', '‼️ double exclamation'),
    (r'🔊', '🔊 sound'),
    (r'📢', '📢 announcement'),
    (r'✅', '✅ check/clear'),
    (r'❌', '❌ cross/negative'),
    (r'🇺🇦', '🇺🇦 Ukraine flag'),
    (r'🎯', '🎯 target'),
    (r'⬆️', '⬆️ up'),
    (r'⬇️', '⬇️ down'),
    (r'➡️', '➡️ right'),
    (r'⬅️', '⬅️ left'),
    (r'↗️', '↗️ up-right'),
    (r'↘️', '↘️ down-right'),
    (r'↙️', '↙️ down-left'),
    (r'↖️', '↖️ up-left'),
    (r'🏠', '🏠 house/shelter'),
    (r'🏢', '🏢 building'),
    (r'📍', '📍 location'),
    (r'🗺', '🗺 map'),
    (r'🆘', '🆘 SOS'),
    (r'☠️', '☠️ danger'),
    (r'💀', '💀 skull'),
    (r'🔻', '🔻 down triangle'),
    (r'🔺', '🔺 up triangle'),
    (r'🌙', '🌙 night'),
    (r'☁️', '☁️ cloud'),
    (r'🌧', '🌧 rain'),
    (r'🐝', '🐝 bee (drone slang)'),
    (r'🐦', '🐦 bird (drone slang)'),
    (r'🦅', '🦅 eagle'),
    (r'🐔', '🐔 chicken (shaheed slang)'),
    (r'🐓', '🐓 rooster'),
    (r'🐻', '🐻 bear (Russia)'),
    (r'🪖', '🪖 military'),
    (r'🛡', '🛡 shield/defence'),
    (r'☢️', '☢️ radiation'),
    (r'📛', '📛 name/alert badge'),
]

# Clear/відбій patterns
CLEAR_PATTERNS = [
    (r'відбій\s*(?:тривог[иі])?', 'відбій (тривоги)'),
    (r'відбою', 'відбою'),
    (r'загроз[аиу]\s+(?:минул[аи]|відступил[аи])', 'загроза минула'),
    (r'чист[еоа]\s+неб[оа]', 'чисте небо'),
    (r'тривог[аиу]\s+(?:завершен|скасован|знят)', 'тривога завершена'),
    (r'все\s+чисто', 'все чисто'),
    (r'без\s+загроз', 'без загроз'),
    (r'небо\s+чист[еоа]', 'небо чисте'),
    (r'кінець\s+тривог', 'кінець тривоги'),
]

# Threat type text patterns
THREAT_TEXT_PATTERNS = [
    (r'шахед|shaheed|shahed|shahed[-\s]?\d*', 'Шахед/Shaheed'),
    (r'бпла|БпЛА|БПЛА', 'БПЛА'),
    (r'дрон[іиоау]?', 'дрон'),
    (r'ракет[аиу]', 'ракета'),
    (r'крилат[аиу]\s+ракет', 'крилата ракета'),
    (r'балістич', 'балістична'),
    (r'(?:КР|кр)\b', 'КР (крилата ракета)'),
    (r'(?:МіГ|міг|Міг)[-\s]?\d*', 'МіГ'),
    (r'(?:Ту|ТУ|ту)[-\s]?\d+', 'Ту-xx'),
    (r'(?:Х|х)[-\s]?\d+', 'Х-xx ракета'),
    (r'(?:Кінжал|кінжал)', 'Кінжал'),
    (r'(?:Іскандер|іскандер)', 'Іскандер'),
    (r'(?:Калібр|калібр)', 'Калібр'),
    (r'(?:С-300|с-300)', 'С-300'),
    (r'гіперзвук', 'гіперзвукова'),
    (r'зондаж|розвід', 'зондажна/розвідка'),
    (r'герань|geran', 'Герань'),
    (r'моп[ед]', 'мопед (слэнг для дрона)'),
]

# Reply / reference patterns
REPLY_PATTERNS = [
    (r'(?:👆|☝️|⬆️)\s*(?:оновлення|update|upd)', 'pointer + update'),
    (r'(?:оновлено|upd|update|UPD)[:\s]', 'update prefix'),
    (r'(?:пост|повідомлення)\s+вище', 'пост/повідомлення вище'),
    (r'(?:додано|додаток)\s*[:\s]', 'додано/додаток'),
    (r'(?:продовження|далі)', 'продовження'),
    (r'(?:#\w+)', 'hashtags'),
    (r'(?:re:|RE:|Re:)', 're: prefix'),
    (r'(?:раніше\s+(?:повідомляли|писали))', 'раніше повідомляли'),
]


# ── Ukrainian location candidate extractor ──────────────────────────────────
# Regex to find Ukrainian proper noun candidates (capitalized Ukrainian words)
# Using explicit Unicode code points to avoid encoding issues
_UPPER_CYR = '\u0410-\u042F\u0406\u0407\u0404\u0490'  # А-Я І Ї Є Ґ
_LOWER_CYR = '\u0430-\u044F\u0456\u0457\u0454\u0491'  # а-я і ї є ґ
LOCATION_CANDIDATE_RE = re.compile(
    r'\b([' + _UPPER_CYR + r'][' + _LOWER_CYR + r"'\u2019\u02BC]{2,}"
    r'(?:[-\s][' + _UPPER_CYR + r'][' + _LOWER_CYR + r"'\u2019\u02BC]{2,})?)\b"
)

PREP_CANDIDATE_RE = re.compile(
    r'(?:на|через|біля|поблизу|район[іу]?|повз|від|з|із|в бік|у бік|курсом на|вектор на)\s+([А-ЯІЇЄҐ][а-яіїєґ\x27ʼ\-]{3,})'
)

# Words to exclude from location candidates
NON_LOCATION_WORDS = {
    'Увага', 'Уваги', 'Тривога', 'Тривоги', 'Загроза', 'Загрози', 'Повітряна', 'Ракетна', 'Протиповітряна',
    'Небезпека', 'Відбій', 'Дрон', 'Дрони', 'Шахед', 'Шахеди', 'Шахеда', 'Бпла', 'Ракета', 'Ракети',
    'Вибух', 'Вибухи', 'Постріл', 'Пуск', 'Пуски', 'Зліт', 'Захід', 'Схід',
    'Північ', 'Південь', 'Україна', 'України', 'Росія', 'Крим', 'Донбас', 'Київщина', 'Київщини', 'Київська',
    'Підписатися', 'Підтримати', 'Читати', 'Далі', 'Також', 'Через',
    'Після', 'Перед', 'Близько', 'Понад', 'Більше', 'Менше', 'Частин',
    'Повідомляє', 'Повідомляють', 'Повідомлення', 'Зберігайте', 'Спокій',
    'Курс', 'Курсом', 'Напрямок', 'Напрямку', 'Вектор', 'Сектор', 'Секторі',
    'Район', 'Району', 'Область', 'Області', 'Сили', 'Оборони', 'Зенітна',
    'Засоби', 'Протиповітряної', 'Працюють', 'Збиті', 'Знищені', 'Збиття',
    'Оперативний', 'Командування', 'Генеральний', 'Штаб', 'Зведення',
    'Ситуація', 'Інформація', 'Дані', 'Ефіри', 'Ефір', 'Карта',
    'Головне', 'Важливо', 'Терміново', 'Друзі', 'Зранку', 'Вночі',
    'Вранці', 'Сьогодні', 'Вчора', 'Наразі', 'Зараз', 'Щойно',
    'Попередня', 'Наступна', 'Остання', 'Перша', 'Друга', 'Третя',
    'Канал', 'Джерело', 'Підписуйтесь', 'Офіційний', 'Москва',
    'Група', 'Групи', 'Черга', 'Серія', 'Хвиля', 'Старт',
    'Повітря', 'Зведення', 'Результат', 'Підсумок', 'Разом', 'Всього',
    'Надходить', 'Летить', 'Летять', 'Працює', 'Працюють', 'Прийняли', 'Чисто',
    'Один', 'Одна', 'Одне', 'Одні', 'Два', 'Дві', 'Три', 'Чотири', "П'ять", 'Пʼять',
    'Шість', 'Сім', 'Вісім', "Дев'ять", 'Девʼять', 'Десять', 'Декілька', 'Кілька',
    'Перший', 'Другий', 'Третій', 'Четвертий', 'Слідкуйте', 'Дивіться', 'Повідомляйте',
    'Полтавський', 'Полтавська', 'Полтавської', 'Полтавщину', 'Чернігівський', 'Чернігівська',
    'Чернігівської', 'Чернігівщину', 'Черкаський', 'Черкаська', 'Черкаської', 'Черкащину',
    'Житомирський', 'Житомирська', 'Житомирської', 'Житомирщину', 'Сумський', 'Сумська',
    'Сумської', 'Сумщину', 'Вінницький', 'Вінницька', 'Вінницької', 'Вінниччину',
    'Одеський', 'Одеська', 'Одеської', 'Одещину'
}
NON_LOCATION_LOWER = {w.lower() for w in NON_LOCATION_WORDS}


def find_location_candidates(text):
    """Extract potential location names from text."""
    candidates = set()
    for match in LOCATION_CANDIDATE_RE.finditer(text):
        word = match.group(1)
        if word.lower() not in NON_LOCATION_LOWER and len(word) > 2:
            candidates.add(word)
    return candidates


def is_known_location(candidate):
    """Check if a candidate location matches any known location key or display name."""
    c_lower = candidate.lower()
    # Check full match in display names
    if c_lower in KNOWN_DISPLAY_NAMES_LOWER:
        return True
    # Check if any key is a prefix of (or matches) the candidate
    for key in KNOWN_LOCATION_KEYS:
        if c_lower.startswith(key) or key.startswith(c_lower):
            return True
    return False


def find_all_emojis(text):
    """Extract all emoji characters/sequences from text."""
    emoji_re = re.compile(
        "["
        "\U0001F600-\U0001F64F"  # emoticons
        "\U0001F300-\U0001F5FF"  # symbols & pictographs
        "\U0001F680-\U0001F6FF"  # transport & map
        "\U0001F1E0-\U0001F1FF"  # flags
        "\U00002702-\U000027B0"
        "\U000024C2-\U0001F251"
        "\U0001F900-\U0001F9FF"  # supplemental symbols
        "\U0001FA00-\U0001FA6F"
        "\U0001FA70-\U0001FAFF"
        "\U00002600-\U000026FF"  # misc symbols
        "\U0000FE00-\U0000FE0F"  # variation selectors
        "\U0000200D"             # ZWJ
        "\U00002000-\U0000206F"  # general punctuation (includes some)
        "\U00002B50-\U00002B55"
        "\U0000203C\U00002049"   # ‼️⁉️
        "\U000020E3"             # combining enclosing keycap
        "\U00000023\U0000002A\U00000030-\U00000039"  # # * 0-9
        "]+", flags=re.UNICODE
    )
    return emoji_re.findall(text)


# ── Main analysis ───────────────────────────────────────────────────────────
def main():
    print("=" * 80)
    print("TELEGRAM CHANNEL MESSAGE ANALYZER")
    print(f"Run at: {datetime.now().isoformat()}")
    print("=" * 80)

    # ── Fetch messages ──────────────────────────────────────────────────────
    all_messages = {}
    total_count = 0

    # 1. Load backend/chyste_nebo_dump.txt
    if os.path.exists(DUMP_PATH):
        try:
            with open(DUMP_PATH, "r", encoding="utf-8") as f:
                dump_text = f.read()
                dump_msgs = [m.strip() for m in dump_text.split("====================") if m.strip()]
                all_messages["chyste_nebo_dump"] = dump_msgs
                total_count += len(dump_msgs)
                print(f"Loaded {len(dump_msgs)} messages from chyste_nebo_dump.txt")
        except Exception as e:
            print(f"⚠️ Failed to load dump {DUMP_PATH}: {e}")

    # 2. Fetch live messages from Telegram web preview
    for ch in CHANNELS:
        print(f"\nFetching: t.me/s/{ch} ...")
        msgs = fetch_channel_messages(ch)
        all_messages[ch] = msgs
        total_count += len(msgs)
        print(f"  -> Got {len(msgs)} messages")

    print(f"\n{'='*80}")
    print(f"TOTAL MESSAGES INGESTED: {total_count}")
    print(f"{'='*80}")

    if total_count == 0:
        print("\n⚠️  No messages fetched or loaded!")
        return

    # ── Collect all texts ───────────────────────────────────────────────────
    flat_messages = []
    for ch, msgs in all_messages.items():
        for msg in msgs:
            flat_messages.append((ch, msg))

    # ── Analysis containers ─────────────────────────────────────────────────
    direction_matches = defaultdict(list)       # pattern -> list of (ch, snippet)
    quantity_matches = defaultdict(list)
    threat_emoji_counter = Counter()
    all_emojis_counter = Counter()
    threat_text_matches = defaultdict(list)
    clear_matches = defaultdict(list)
    reply_matches = defaultdict(list)
    unknown_locations = Counter()               # location -> count
    known_locations_found = Counter()
    message_structures = []                     # messages that don't match typical patterns
    raw_quantity_values = Counter()

    # ── Analyze each message ────────────────────────────────────────────────
    for ch, text in flat_messages:
        text_lower = text.lower()

        # 1) Direction patterns
        for pat, label in DIRECTION_PATTERNS:
            for m in re.finditer(pat, text_lower):
                snippet = text[max(0, m.start()-20):m.end()+30].replace('\n', ' ')
                direction_matches[label].append((ch, m.group(), snippet))

        # 2) Quantity patterns
        for pat, label in QUANTITY_PATTERNS:
            for m in re.finditer(pat, text_lower):
                snippet = text[max(0, m.start()-15):m.end()+25].replace('\n', ' ')
                quantity_matches[label].append((ch, m.group(), snippet))
                # Extract actual number if captured
                if m.groups():
                    raw_quantity_values[m.group(1)] += 1

        # 3) Threat emoji
        for pat, label in THREAT_TYPE_EMOJI_PATTERNS:
            count = len(re.findall(pat, text))
            if count:
                threat_emoji_counter[label] += count

        # All emojis
        for emoji in find_all_emojis(text):
            all_emojis_counter[emoji] += 1

        # 4) Threat text
        for pat, label in THREAT_TEXT_PATTERNS:
            for m in re.finditer(pat, text, re.IGNORECASE):
                snippet = text[max(0, m.start()-15):m.end()+25].replace('\n', ' ')
                threat_text_matches[label].append((ch, m.group(), snippet))

        # 5) Clear / відбій
        for pat, label in CLEAR_PATTERNS:
            for m in re.finditer(pat, text_lower):
                snippet = text[max(0, m.start()-10):m.end()+40].replace('\n', ' ')
                clear_matches[label].append((ch, m.group(), snippet))

        # 6) Reply/reference patterns
        for pat, label in REPLY_PATTERNS:
            for m in re.finditer(pat, text):
                snippet = text[max(0, m.start()-10):m.end()+30].replace('\n', ' ')
                reply_matches[label].append((ch, m.group(), snippet))

        # 7) Location candidates (General + Preposition-anchored)
        for loc in find_location_candidates(text):
            if is_known_location(loc):
                known_locations_found[loc] += 1
            else:
                unknown_locations[loc] += 1

        for m in PREP_CANDIDATE_RE.finditer(text):
            loc = m.group(1)
            if loc.lower() not in NON_LOCATION_LOWER and len(loc) > 2:
                if is_known_location(loc):
                    known_locations_found[loc] += 2
                else:
                    unknown_locations[loc] += 3

        # 8) Check if message matches any "typical" alert pattern
        typical = False
        typical_patterns = [
            r'тривог[аиу]',
            r'відбій',
            r'(?:бпла|дрон|шахед|ракет)',
            r'(?:вибух|прильот)',
            r'(?:загроз[аи])',
            r'(?:повітрян)',
        ]
        for tp in typical_patterns:
            if re.search(tp, text_lower):
                typical = True
                break
        if not typical and len(text) > 20:
            message_structures.append((ch, text[:200]))

    # ── Output report ───────────────────────────────────────────────────────
    print("\n")
    print("=" * 80)
    print("                         ANALYSIS REPORT")
    print("=" * 80)

    # A) Unknown locations
    print("\n" + "─" * 80)
    print("A) UNKNOWN LOCATION NAMES (not in _kKyivLocations)")
    print("   Sorted by frequency")
    print("─" * 80)
    if unknown_locations:
        for loc, cnt in unknown_locations.most_common(80):
            print(f"   {cnt:3d}x  {loc}")
    else:
        print("   (none found)")

    # B) Known locations found
    print("\n" + "─" * 80)
    print("B) KNOWN LOCATIONS FOUND (confirming dictionary coverage)")
    print("─" * 80)
    for loc, cnt in known_locations_found.most_common(40):
        print(f"   {cnt:3d}x  {loc}")

    # C) Directional patterns
    print("\n" + "─" * 80)
    print("C) DIRECTIONAL PATTERNS FOUND")
    print("─" * 80)
    for label, matches in sorted(direction_matches.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(matches)}x] {label}")
        for ch, matched, snippet in matches[:5]:
            print(f"       @{ch}: \"{matched}\"  ...context: «{snippet}»")
        if len(matches) > 5:
            print(f"       ... and {len(matches)-5} more")

    # D) Quantity patterns
    print("\n" + "─" * 80)
    print("D) QUANTITY PATTERNS FOUND")
    print("─" * 80)
    for label, matches in sorted(quantity_matches.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(matches)}x] {label}")
        for ch, matched, snippet in matches[:5]:
            print(f"       @{ch}: \"{matched}\"  ...context: «{snippet}»")
        if len(matches) > 5:
            print(f"       ... and {len(matches)-5} more")

    print("\n  Raw numeric values found:")
    for val, cnt in raw_quantity_values.most_common(20):
        print(f"    {cnt:3d}x  value={val}")

    # E) Threat type indicators
    print("\n" + "─" * 80)
    print("E) THREAT TYPE INDICATORS")
    print("─" * 80)

    print("\n  E.1) Emoji-based threat types:")
    for label, cnt in threat_emoji_counter.most_common():
        print(f"    {cnt:3d}x  {label}")

    print("\n  E.2) All unique emojis found:")
    for emoji, cnt in all_emojis_counter.most_common(40):
        print(f"    {cnt:3d}x  {emoji}")

    print("\n  E.3) Text-based threat types:")
    for label, matches in sorted(threat_text_matches.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(matches)}x] {label}")
        for ch, matched, snippet in matches[:3]:
            print(f"       @{ch}: \"{matched}\"  → «{snippet}»")
        if len(matches) > 3:
            print(f"       ... and {len(matches)-3} more")

    # F) Clear/відбій patterns
    print("\n" + "─" * 80)
    print("F) CLEAR / ВІДБІЙ PATTERNS")
    print("─" * 80)
    for label, matches in sorted(clear_matches.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(matches)}x] {label}")
        for ch, matched, snippet in matches[:5]:
            print(f"       @{ch}: \"{matched}\"  → «{snippet}»")

    # G) Reply / reference patterns
    print("\n" + "─" * 80)
    print("G) REPLY / REFERENCE PATTERNS")
    print("─" * 80)
    for label, matches in sorted(reply_matches.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(matches)}x] {label}")
        for ch, matched, snippet in matches[:5]:
            print(f"       @{ch}: \"{matched}\"  → «{snippet}»")

    # H) Messages that our parser might miss
    print("\n" + "─" * 80)
    print("H) MESSAGES THAT MIGHT NOT MATCH TYPICAL ALERT PATTERNS")
    print("   (no тривога/відбій/бпла/дрон/ракет/вибух/загроза keywords)")
    print("─" * 80)
    for ch, snippet in message_structures[:30]:
        print(f"\n  @{ch}:")
        print(f"    «{snippet}»")
    if len(message_structures) > 30:
        print(f"\n  ... and {len(message_structures) - 30} more atypical messages")

    # I) Sample raw messages for manual review
    print("\n" + "─" * 80)
    print("I) SAMPLE RAW MESSAGES (first 5 per channel)")
    print("─" * 80)
    for ch, msgs in all_messages.items():
        print(f"\n  ── @{ch} ({len(msgs)} total) ──")
        for i, msg in enumerate(msgs[:5]):
            preview = msg[:200].replace('\n', '\\n')
            print(f"    [{i+1}] {preview}")

    # J) Nominatim geocoding & remote_config update for top candidates
    print("\n" + "─" * 80)
    print("J) NOMINATIM GEOCODING & REMOTE CONFIG UPDATE")
    print("─" * 80)

    existing_extra = {}
    if os.path.exists(REMOTE_CONFIG_PATH):
        try:
            with open(REMOTE_CONFIG_PATH, "r", encoding="utf-8") as f:
                existing_extra = json.load(f).get("extra_locations", {})
        except Exception:
            pass

    verified_new_locations = {}
    candidates_to_check = [loc for loc, _ in unknown_locations.most_common(30)]
    print(f"Checking candidate unknown locations via OpenStreetMap Nominatim...")

    checked_count = 0
    for cand in candidates_to_check:
        if len(cand) < 4:
            continue
        stem = stem_location(cand)
        if stem in KNOWN_LOCATION_KEYS or stem in existing_extra or stem in verified_new_locations:
            continue
        if cand.lower() in NON_LOCATION_LOWER:
            continue
        print(f"  -> Geocoding: '{cand}' (stem: {stem}) ...")
        res = geocode_candidate(cand)
        checked_count += 1
        time.sleep(0.8)  # respect OSM Nominatim rate limits
        if res:
            lat, lon, disp_name = res
            verified_new_locations[stem] = {
                "lat": lat,
                "lon": lon,
                "name": disp_name
            }
            print(f"     ✅ Found in Kyiv Oblast: {disp_name} ({lat:.4f}, {lon:.4f})")
        else:
            print(f"     ❌ Not found or outside Kyiv Oblast")
        if checked_count >= 15:
            break

    if verified_new_locations:
        print(f"\nWriting {len(verified_new_locations)} new verified locations to {REMOTE_CONFIG_PATH}...")
        update_remote_config_with_locations(verified_new_locations)
    else:
        print("\nNo new valid Kyiv Oblast locations found to add.")

    print("\n" + "=" * 80)
    print("                      END OF REPORT")
    print("=" * 80)


if __name__ == '__main__':
    main()
