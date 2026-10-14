import urllib.request
import re
import json

html = urllib.request.urlopen(urllib.request.Request('https://t.me/s/chyste_nebo', headers={'User-Agent': 'Mozilla/5.0'})).read().decode('utf-8')
msgs = re.findall(r'tgme_widget_message_text[^>]*>(.*?)</div>', html, re.DOTALL)
with open('dump.txt', 'w', encoding='utf-8') as f:
    for m in msgs[-50:]:
        f.write(m + "\n---\n")
