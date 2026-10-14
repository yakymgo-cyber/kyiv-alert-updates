import re

def update_backend_parser(path):
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()

    # We want to replace the part that appends to parsed_threats
    target = '''        parsed_threats.append({
            "type": line_threat["type"],
            "speed": line_threat["speed"],
            "path": path
        })'''

    replacement = '''        quantity = 1
        q_match = re.search(r'(?:^|[\\s\\W_])([1-9]|один|два|три|чотири|п\\'ять|шість|декілька|кілька)\\s*(?:х|x|шт|штук|шт\\.)?(?:\\s|$)', line_lower)
        if q_match:
            q_str = q_match.group(1)
            if q_str in ['декілька', 'кілька']: quantity = 3
            elif q_str == 'один': quantity = 1
            elif q_str == 'два': quantity = 2
            elif q_str == 'три': quantity = 3
            elif q_str == 'чотири': quantity = 4
            elif q_str == 'п\\'ять': quantity = 5
            elif q_str == 'шість': quantity = 6
            elif q_str.isdigit(): quantity = int(q_str)
            
        for _ in range(quantity):
            parsed_threats.append({
                "type": line_threat["type"],
                "speed": line_threat["speed"],
                "path": list(path)
            })'''

    c = c.replace(target, replacement)
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

update_backend_parser('C:/Projects/kyiv-alert-app/backend/telegram_client.py')
