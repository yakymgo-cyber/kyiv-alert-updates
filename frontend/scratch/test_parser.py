import json
import re

def analyze_local_threat(text):
    tLower = text.lower()
    if 'кинджал' in tLower or 'циркон' in tLower or 'гіперзвук' in tLower:
        return {'type': 'missile_hypersonic', 'speed': 12000.0}
    elif 'баліст' in tLower or 'іскандер' in tLower or 'кн-23' in tLower or 'kn-23' in tLower or '☄' in tLower:
        return {'type': 'missile_ballistic', 'speed': 5000.0}
    elif 'крилат' in tLower or 'х-101' in tLower or 'калібр' in tLower or 'онікс' in tLower or ('ракет' in tLower and 'реактив' not in tLower):
        return {'type': 'missile_cruise', 'speed': 900.0}
    if 'звичайний' in tLower or 'не реактив' in tLower or 'двз' in tLower or 'мопед' in tLower:
        return {'type': 'shahed', 'speed': 185.0}
    return {'type': 'shahed_jet', 'speed': 500.0}

def parse(text):
    tLower = text.lower()
    globalThreat = analyze_local_threat(text)
    
    # hasMultipleDrones
    hasMultipleDrones = re.search(r'(?:^|\s)(?:[1-9]\s*(?:х|x|шт)?|ще один|кілька|групи|декілька)(?:\s|$)', tLower)
    lines = text.split('\n') if hasMultipleDrones else [text.replace('\n', ' ')]
    
    parsed = []
    for line in lines:
        stripped = line.strip()
        if not stripped: continue
        lineLower = ' ' + stripped.lower() + ' '
        
        lineThreat = analyze_local_threat(line)
        print(f"Line: {line}")
        print(f"LineThreat: {lineThreat}")
        
parse("!! Київ — спуск балістики&#33;")
parse("⏺ ❗ 2х Циркона на Київ&#33;&#33;")
