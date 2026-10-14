import re

def update_main_dart(path):
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()
    
    # 1. Add jitter
    jitter_code = '''
                                        final rnd = math.Random((lat + lon + msg['id']).hashCode);
                                        lat += (rnd.nextDouble() - 0.5) * 0.02;
                                        lon += (rnd.nextDouble() - 0.5) * 0.02;
                                        final pt = LatLng(lat, lon);'''
    c = c.replace('final pt = LatLng(lat, lon);', jitter_code)

    # 2. Add directional start point if path has 1 point
    dir_code = '''
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
                                  
                                  if (path.isEmpty) continue;'''
                                  
    c = c.replace('if (path.isEmpty) continue;', dir_code)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)

update_main_dart('C:/Projects/kyiv-alert-app/frontend/lib/main.dart')
