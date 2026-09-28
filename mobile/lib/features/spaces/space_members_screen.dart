import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';

/// Участники пространства. Для чужого открытого пространства сервер отдаёт
/// только «инсайдеров» (dating_switch = 1); для своего — всех.
class SpaceMembersScreen extends StatefulWidget {
  final int spaceId;
  final String spaceName;

  const SpaceMembersScreen({
    super.key,
    required this.spaceId,
    required this.spaceName,
  });

  @override
  State<SpaceMembersScreen> createState() => _SpaceMembersScreenState();
}

class _SpaceMembersScreenState extends State<SpaceMembersScreen> {
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.instance.listSpaceMembers(widget.spaceId);
      if (mounted) {
        setState(() {
          _members = (res['members'] as List)
              .map((m) => Map<String, dynamic>.from(m as Map))
              .toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.spaceName.isNotEmpty ? widget.spaceName : S.spacesTitle;
    return AppScaffold(
      title: name,
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _members.isEmpty
              ? const EmptyState(
                  icon: Icons.group_off,
                  title: 'Участников не видно',
                  hint:
                      'В этом открытом пространстве никто не включил межпространственность.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _members.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = _members[i];
                    final uname = m['username'] as String? ?? '';
                    final display =
                        (m['display_name'] as String?)?.isNotEmpty == true
                            ? m['display_name'] as String
                            : uname;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                        child: Text(
                          display.isNotEmpty ? display[0].toUpperCase() : '?',
                        ),
                      ),
                      title: Text(display),
                      subtitle: Text('@$uname'),
                      onTap: () => context.go('/home/contact/@$uname'),
                    );
                  },
                ),
    );
  }
}
