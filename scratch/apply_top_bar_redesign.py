# -*- coding: utf-8 -*-
import sys

with open('frontend/lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update _MainScreenState declaration to mixin SingleTickerProviderStateMixin
old_class_decl = "class _MainScreenState extends ConsumerState<MainScreen> with WidgetsBindingObserver {"
new_class_decl = """class _MainScreenState extends ConsumerState<MainScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _isSettingsMenuOpen = false;
  late final AnimationController _settingsAnimController;
  late final Animation<double> _settingsAnimation;

  void _toggleSettingsMenu() {
    setState(() {
      _isSettingsMenuOpen = !_isSettingsMenuOpen;
      if (_isSettingsMenuOpen) {
        _settingsAnimController.forward();
      } else {
        _settingsAnimController.reverse();
      }
    });
  }

  void _closeSettingsMenu() {
    if (_isSettingsMenuOpen) {
      setState(() {
        _isSettingsMenuOpen = false;
        _settingsAnimController.reverse();
      });
    }
  }"""

assert old_class_decl in content, "old_class_decl not found"
content = content.replace(old_class_decl, new_class_decl, 1)

# 2. Update initState to initialize animation controller
old_init_state = """  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);"""

new_init_state = """  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _settingsAnimation = CurvedAnimation(
      parent: _settingsAnimController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );"""

assert old_init_state in content, "old_init_state not found"
content = content.replace(old_init_state, new_init_state, 1)

# 3. Update dispose to dispose animation controller
old_dispose = """  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);"""

new_dispose = """  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsAnimController.dispose();"""

assert old_dispose in content, "old_dispose not found"
content = content.replace(old_dispose, new_dispose, 1)

# 4. Update AppBar actions and body start
old_appbar_and_body = """    return Scaffold(
      appBar: AppBar(
        title: const Text('Kyiv Alert 🇺🇦', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update_alt_rounded, color: Colors.cyanAccent),
            tooltip: 'Перевірити оновлення',
            onPressed: () => _manualCheckForUpdates(context),
          ),
          IconButton(
            icon: const Icon(Icons.coffee_outlined, color: Colors.amberAccent),
            tooltip: 'Ранковий брифінг',
            onPressed: () => _showMorningDigestSheet(context),
          ),
          IconButton(
            icon: Icon(_isNightWatchMode ? Icons.bedtime : Icons.bedtime_outlined),
            color: _isNightWatchMode ? Colors.amberAccent : Colors.grey,
            tooltip: _isNightWatchMode ? "Режим 'Нічний вартовий' (УВІМКНЕНО, +3.5 км до зон)" : "Режим 'Нічний вартовий' (Вимкнено)",
            onPressed: () {
              setState(() {
                _isNightWatchMode = !_isNightWatchMode;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _isNightWatchMode
                        ? '🌙 Режим "Нічний вартовий" увімкнено! Радіус зон розширено на +3.5 км, увімкнено готовність до гучних сигналів тривоги.'
                        : '☀️ Режим "Нічний вартовий" вимкнено.',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  duration: const Duration(seconds: 3),
                  backgroundColor: _isNightWatchMode ? const Color(0xFF2A164D) : const Color(0xFF2C2C34),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit_location_alt_outlined, color: Colors.purpleAccent),
            tooltip: 'Мої зони безпеки',
            onPressed: () => _showWatchedLocationsSheet(context),
          ),
          IconButton(
            icon: Icon(VoiceAlertService.instance.isEnabled ? Icons.record_voice_over : Icons.voice_over_off),
            color: VoiceAlertService.instance.isEnabled ? Colors.cyanAccent : Colors.grey,
            tooltip: VoiceAlertService.instance.isEnabled ? "Голосовий диктор (УВІМКНЕНО)" : "Голосовий диктор (Вимкнено)",
            onPressed: () async {
              await VoiceAlertService.instance.setEnabled(!VoiceAlertService.instance.isEnabled);
              if (!mounted) return;
              setState(() {});
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    VoiceAlertService.instance.isEnabled
                        ? '🔊 Голосовий диктор увімкнено! Сповіщення озвучуватимуться українською.'
                        : '🔇 Голосовий диктор вимкнено.',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  duration: const Duration(seconds: 2),
                  backgroundColor: VoiceAlertService.instance.isEnabled ? const Color(0xFF004D40) : const Color(0xFF2C2C34),
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(isTestMode ? Icons.bug_report : Icons.bug_report_outlined),
            color: isTestMode ? Colors.greenAccent : Colors.grey,
            tooltip: 'Тестовий режим',
            onPressed: () {
              ref.read(testModeProvider.notifier).toggle();
                _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
            },
          )
        ],
      ),
      body: isLoadingInitial 
        ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
        : Column(
            children: [
              if (hasUpdate) _buildUpdateBanner(remoteConfig),"""

new_appbar_and_body = """    return Scaffold(
      appBar: AppBar(
        title: const Text('Kyiv Alert 🇺🇦', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.coffee_outlined, color: Colors.amberAccent),
            tooltip: 'Зведення (Ранковий брифінг)',
            onPressed: () {
              _closeSettingsMenu();
              _showMorningDigestSheet(context);
            },
          ),
          IconButton(
            icon: Icon(_isNightWatchMode ? Icons.bedtime : Icons.bedtime_outlined),
            color: _isNightWatchMode ? Colors.amberAccent : Colors.grey,
            tooltip: _isNightWatchMode ? "Режим 'Нічний вартовий' (УВІМКНЕНО, +3.5 км до зон)" : "Режим 'Нічний вартовий' (Вимкнено)",
            onPressed: () {
              setState(() {
                _isNightWatchMode = !_isNightWatchMode;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _isNightWatchMode
                        ? '🌙 Режим "Нічний вартовий" увімкнено! Радіус зон розширено на +3.5 км, увімкнено готовність до гучних сигналів тривоги.'
                        : '☀️ Режим "Нічний вартовий" вимкнено.',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  duration: const Duration(seconds: 3),
                  backgroundColor: _isNightWatchMode ? const Color(0xFF2A164D) : const Color(0xFF2C2C34),
                ),
              );
            },
          ),
          IconButton(
            icon: AnimatedRotation(
              turns: _isSettingsMenuOpen ? 0.25 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _isSettingsMenuOpen ? Icons.close_rounded : Icons.tune_rounded,
                color: _isSettingsMenuOpen ? Colors.cyanAccent : Colors.white70,
              ),
            ),
            tooltip: 'Налаштування та інструменти',
            onPressed: _toggleSettingsMenu,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: isLoadingInitial 
        ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
        : Stack(
            children: [
              Column(
                children: [
                  if (hasUpdate) _buildUpdateBanner(remoteConfig),"""

assert old_appbar_and_body in content, "old_appbar_and_body not found"
content = content.replace(old_appbar_and_body, new_appbar_and_body, 1)

# 5. Update body closing and add dropdown menu helper methods inside _MainScreenState
old_body_and_class_end = """                return isWide ? Row(children: [mapWidget, listWidget]) : Column(children: [mapWidget, listWidget]);
              }
            ),
          ),
        ],
      ),
    );
  }
}

Widget _buildThreatAssetIcon(String type, {double? size}) {"""

new_body_and_class_end = """                return isWide ? Row(children: [mapWidget, listWidget]) : Column(children: [mapWidget, listWidget]);
              }
            ),
          ),
        ],
      ),
      if (_isSettingsMenuOpen)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeSettingsMenu,
            child: Container(
              color: Colors.black.withValues(alpha: 0.2),
            ),
          ),
        ),
      Positioned(
        top: 6,
        right: 8,
        child: SizeTransition(
          sizeFactor: _settingsAnimation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: _settingsAnimation,
            child: _buildSettingsDropdownMenu(context, isTestMode, watchedLocations, remoteConfig),
          ),
        ),
      ),
    ],
  ),
);
  }

  Widget _buildSettingsDropdownMenu(
    BuildContext context,
    bool isTestMode,
    List<WatchedLocation> watchedLocations,
    RemoteConfig remoteConfig,
  ) {
    final bool hasUpdate = remoteConfig.versionCode > kCurrentVersionCode && remoteConfig.apkUrl.isNotEmpty;
    final isVoiceEnabled = VoiceAlertService.instance.isEnabled;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 255,
        decoration: BoxDecoration(
          color: const Color(0xF71C1D26),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 20,
              spreadRadius: 2,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 16, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  Text(
                    'НАЛАШТУВАННЯ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
            _buildDropdownItem(
              icon: Icons.edit_location_alt_outlined,
              iconColor: Colors.purpleAccent,
              title: 'Мої зони безпеки',
              subtitle: '${watchedLocations.length} зон під наглядом',
              onTap: () {
                _closeSettingsMenu();
                _showWatchedLocationsSheet(context);
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: isVoiceEnabled ? Icons.record_voice_over : Icons.voice_over_off,
              iconColor: isVoiceEnabled ? Colors.cyanAccent : Colors.grey,
              title: 'Голосовий диктор',
              subtitle: isVoiceEnabled ? 'Озвучення увімкнено' : 'Вимкнено',
              trailing: Transform.scale(
                scale: 0.75,
                child: Switch.adaptive(
                  value: isVoiceEnabled,
                  activeColor: Colors.cyanAccent,
                  onChanged: (val) async {
                    await VoiceAlertService.instance.setEnabled(val);
                    if (!mounted) return;
                    setState(() {});
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          val
                              ? '🔊 Голосовий диктор увімкнено! Сповіщення озвучуватимуться українською.'
                              : '🔇 Голосовий диктор вимкнено.',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        duration: const Duration(seconds: 2),
                        backgroundColor: val ? const Color(0xFF004D40) : const Color(0xFF2C2C34),
                      ),
                    );
                  },
                ),
              ),
              onTap: () async {
                final newVal = !isVoiceEnabled;
                await VoiceAlertService.instance.setEnabled(newVal);
                if (!mounted) return;
                setState(() {});
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      newVal
                          ? '🔊 Голосовий диктор увімкнено! Сповіщення озвучуватимуться українською.'
                          : '🔇 Голосовий диктор вимкнено.',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    duration: const Duration(seconds: 2),
                    backgroundColor: newVal ? const Color(0xFF004D40) : const Color(0xFF2C2C34),
                  ),
                );
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: Icons.system_update_alt_rounded,
              iconColor: hasUpdate ? Colors.orangeAccent : Colors.cyanAccent,
              title: 'Перевірити оновлення',
              subtitle: hasUpdate ? 'Доступна нова версія!' : 'Поточна v$kCurrentVersionName',
              trailing: hasUpdate
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.orangeAccent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
              onTap: () {
                _closeSettingsMenu();
                _manualCheckForUpdates(context);
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: isTestMode ? Icons.bug_report : Icons.bug_report_outlined,
              iconColor: isTestMode ? Colors.greenAccent : Colors.grey,
              title: 'Тестовий режим',
              subtitle: isTestMode ? 'Активний (емуляція)' : 'Вимкнено',
              trailing: Transform.scale(
                scale: 0.75,
                child: Switch.adaptive(
                  value: isTestMode,
                  activeColor: Colors.greenAccent,
                  onChanged: (val) {
                    ref.read(testModeProvider.notifier).toggle();
                    _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
                  },
                ),
              ),
              onTap: () {
                ref.read(testModeProvider.notifier).toggle();
                _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconColor.withValues(alpha: 0.35), width: 1),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
}

Widget _buildThreatAssetIcon(String type, {double? size}) {"""

assert old_body_and_class_end in content, "old_body_and_class_end not found"
content = content.replace(old_body_and_class_end, new_body_and_class_end, 1)

diff = content.count('{') - content.count('}')
print('Brace balance diff:', diff)
assert diff == 0, f"Braces unbalanced: diff = {diff}"

with open('frontend/lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print("SUCCESS: Top bar refactored and settings dropdown added successfully!")
