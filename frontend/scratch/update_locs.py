import re

def update_locations(path, dart_mode=False):
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()

    new_locs = '''
    "фурси": (49.771, 29.967, "Фурси"),
    "вільшанк": (49.715, 30.046, "Мала Вільшанка"),
    "бакал": (49.791, 30.026, "Бакали"),
    "сквир": (49.728, 29.683, "Сквира"),
    "володарк": (49.525, 29.919, "Володарка"),
    "дмитрівк": (50.457, 30.019, "Дмитрівка"),
    "петрашівк": (49.764, 30.076, "Петрашівка"),
'''
    if dart_mode:
        new_locs = new_locs.replace('"', "'")
        idx = c.find("'славутич':")
        if idx != -1:
            c = c[:idx] + new_locs + c[idx:]
    else:
        idx = c.find('"славутич":')
        if idx != -1:
            c = c[:idx] + new_locs + c[idx:]

    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

update_locations('C:/Projects/kyiv-alert-app/backend/telegram_client.py')
update_locations('C:/Projects/kyiv-alert-app/frontend/lib/main.dart', dart_mode=True)
