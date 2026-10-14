import re

def update_main_dart(path):
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()

    target_str = "final bool isExplicitRegular"
    
    logic_code = '''
                                  if (path.length == 1) {
                                    double latOffset = 0;
                                    double lonOffset = 0;
                                    if (msgTextLower.contains('з півд') || msgTextLower.contains('півден')) {
                                      latOffset = -0.15;
                                    } else if (msgTextLower.contains('з півн') || msgTextLower.contains('північ')) {
                                      latOffset = 0.15;
                                    } else if (msgTextLower.contains('зі сход') || msgTextLower.contains('східн')) {
                                      lonOffset = 0.2;
                                    } else if (msgTextLower.contains('із заход') || msgTextLower.contains('західн') || msgTextLower.contains('з заход')) {
                                      lonOffset = -0.2;
                                    }
                                    if (latOffset != 0 || lonOffset != 0) {
                                      final target = path.first;
                                      path.insert(0, LatLng(target.latitude + latOffset, target.longitude + lonOffset));
                                      locNames.insert(0, '');
                                    }
                                  }
                                  
                                  if (path.isEmpty) continue;
                                  
                                  for (int i=0; i<path.length; i++) {
                                     final rnd = math.Random((path[i].latitude + path[i].longitude + (msg['id'] as int)).hashCode);
                                     double jLat = (rnd.nextDouble() - 0.5) * 0.02;
                                     double jLon = (rnd.nextDouble() - 0.5) * 0.02;
                                     path[i] = LatLng(path[i].latitude + jLat, path[i].longitude + jLon);
                                  }
                                  
                                  final bool isExplicitRegular'''
                                  
    c = c.replace(target_str, logic_code)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

update_main_dart('C:/Projects/kyiv-alert-app/frontend/lib/main.dart')
