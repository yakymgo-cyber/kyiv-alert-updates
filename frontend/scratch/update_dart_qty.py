import re

def update_dart_regex(path):
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()

    # Find the count regex
    target = r"final match = RegExp(r'(?:^|[\s\W_])([1-9])\s*(?:х|x|шт|штук|шт\.)').firstMatch(lineLower);"
    
    replacement = r'''final match = RegExp(r'(?:^|[\s\W_])([1-9]|один|два|три|чотири|п\'ять|шість|декілька|кілька)\s*(?:х|x|шт|штук|шт\.)?(?:\s|$)', caseSensitive: false).firstMatch(lineLower);
      int count = 1;
      if (match != null) {
        final qStr = match.group(1)!;
        if (qStr == 'декілька' || qStr == 'кілька') count = 3;
        else if (qStr == 'один') count = 1;
        else if (qStr == 'два') count = 2;
        else if (qStr == 'три') count = 3;
        else if (qStr == 'чотири') count = 4;
        else if (qStr == 'п\'ять') count = 5;
        else if (qStr == 'шість') count = 6;
        else count = int.tryParse(qStr) ?? 1;
      }'''

    c = c.replace(target, replacement)
    
    # Also replace 'int count = match != null ? (int.tryParse(match.group(1)!) ?? 1) : 1;' to remove it
    c = c.replace('int count = match != null ? (int.tryParse(match.group(1)!) ?? 1) : 1;', '')

    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

update_dart_regex('C:/Projects/kyiv-alert-app/frontend/lib/main.dart')
