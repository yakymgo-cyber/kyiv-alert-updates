import re
with open('../lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

new_test_messages = """      final allTestMessages = [
          {
            'id': 1011,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Відбій ракетної небезпеки по всій області!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1010,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Київ відбій по шахедам, чисто!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1009,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Шахеди в межах Києва, працює ППО! Залишився один над Оболонню',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1008,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Київ дорозвідка по балістиці. Ракети чисто.',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1007,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Кинджали на Київ!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1006,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'УВАГА! Загроза балістики з Криму на Київ! Іскандер-М',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1005,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Крилаті ракети через Чернігівщину курсом на Київ! Вже біля Славутича!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1004,
            'type': 'info',
            'channel': 'war_monitor',
            'text': 'Пуски крилатих ракет Х-101 з Ту-95мс!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1003,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Шахеди на Фастів та Обухів!',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1002,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Зафіксовано запуск 10х шахедів з півдня, вектор на Білу Церкву',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          },
          {
            'id': 1001,
            'type': 'info',
            'channel': 'war_monitor',
            'text': 'УВАГА! Зліт 4х бортів ТУ-95мс з аеродрому Оленья.',
            'date': DateTime.now().toUtc().toIso8601String(),
            'threats': []
          }
      ];"""

pattern = re.compile(r"      final allTestMessages = \[.*?      \];", re.DOTALL)
new_content = pattern.sub(new_test_messages, content)

with open('../lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(new_content)
