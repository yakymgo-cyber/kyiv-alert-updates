import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Add import
import_stmt = "import 'desktop_map_wrapper.dart';\n"
if "desktop_map_wrapper.dart" not in content:
    content = content.replace("import 'package:flutter_map/flutter_map.dart';", "import 'package:flutter_map/flutter_map.dart';\n" + import_stmt)

# Convert MainScreen to ConsumerStatefulWidget
content = content.replace("class MainScreen extends ConsumerWidget {", "class MainScreen extends ConsumerStatefulWidget {")
content = content.replace("const MainScreen({super.key});\n\n  @override\n  Widget build(BuildContext context, WidgetRef ref) {", """const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  final MapController _mapController = MapController();

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
""")

# Update FlutterMap
flutter_map_start = "FlutterMap("
flutter_map_replacement = """DesktopMapWrapper(
                                  mapController: _mapController,
                                  child: FlutterMap(
                                    mapController: _mapController,"""

content = content.replace("FlutterMap(\n                                options: MapOptions(", flutter_map_replacement + "\n                                options: MapOptions(")

# Update MapOptions interactive flags
interactive_flags_old = "flags: InteractiveFlag.all & ~InteractiveFlag.rotate,"
interactive_flags_new = "flags: InteractiveFlag.all & ~InteractiveFlag.rotate & ~InteractiveFlag.scrollWheelZoom,"
content = content.replace(interactive_flags_old, interactive_flags_new)

# Add closing bracket for DesktopMapWrapper
# The original FlutterMap ends at:
#                                   ],\n                                ),
# Let's use regex to find where FlutterMap ends and wrap it.
content = content.replace("                                  ],\n                                ),\n                                children: [\n", "                                  ],\n                                ),\n                                ),\n                                children: [\n")

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)
print("Updated main.dart")
