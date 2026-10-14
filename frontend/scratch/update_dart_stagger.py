import re

def fix():
    path = 'C:/Projects/kyiv-alert-app/frontend/lib/main.dart'
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()

    # 1. Remove lateral jitter
    jitter_code = '''                                  for (int i=0; i<path.length; i++) {
                                     final rnd = math.Random((path[i].latitude + path[i].longitude + (msg['id'] as int)).hashCode);
                                     double jLat = (rnd.nextDouble() - 0.5) * 0.02;
                                     double jLon = (rnd.nextDouble() - 0.5) * 0.02;
                                     path[i] = LatLng(path[i].latitude + jLat, path[i].longitude + jLon);
                                  }'''
    c = c.replace(jitter_code, '')

    # 2. Add stagger to msgTime
    stagger_target = '''                                  DateTime msgTime;
                                  try {
                                    msgTime = DateTime.parse(msg['date'].toString());
                                  } catch (e) {
                                    msgTime = DateTime.now();
                                  }'''
                                  
    stagger_replace = '''                                  DateTime msgTime;
                                  try {
                                    msgTime = DateTime.parse(msg['date'].toString());
                                  } catch (e) {
                                    msgTime = DateTime.now();
                                  }
                                  // Stagger drones that are spawned from the same message
                                  // threatIdx * 45 seconds makes them fly "one after another"
                                  msgTime = msgTime.add(Duration(seconds: threatIdx * 45));'''

    c = c.replace(stagger_target, stagger_replace)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

fix()
