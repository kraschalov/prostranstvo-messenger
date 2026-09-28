import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/spaces/space_members_screen.dart';
import 'package:mesenger/widgets/common.dart';

/// Подраздел «Открытые пространства»: visible=1, без своих.
class OpenSpacesScreen extends ConsumerStatefulWidget {
  const OpenSpacesScreen({super.key});

  @override
  ConsumerState<OpenSpacesScreen> createState() => _OpenSpacesScreenState();
}

class _OpenSpacesScreenState extends ConsumerState<OpenSpacesScreen> {
  bool _loading = true;
  List<Space> _spaces = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Свои НЕ вычитаем: владелец должен видеть и свои открытые.
      final openRes = await ApiClient.instance.listOpenSpaces();
      final list = ((openRes['spaces'] as List? ?? const [])
              .map((s) => Space.fromJson(Map<String, dynamic>.from(s as Map))))
          .toList();
      if (mounted) {
        setState(() {
          _spaces = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось загрузить: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Открытые пространства',
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.textSecondary)),
                  ),
                )
              : RefreshIndicator(
              onRefresh: _load,
              child: _spaces.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: const [
                        Text(
                          'Открытых пространств пока нет.',
                          style:
                              TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _spaces.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final space = _spaces[i];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.accentAlt
                                  .withValues(alpha: 0.2),
                              child: Text(
                                space.name.isNotEmpty
                                    ? space.name[0].toUpperCase()
                                    : '?',
                              ),
                            ),
                            title: Text(space.name),
                            subtitle: Text(
                              space.description.isEmpty
                                  ? 'Открытое'
                                  : space.description,
                            ),
                            trailing: const Icon(Icons.public,
                                color: AppColors.accentAlt, size: 18),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => SpaceMembersScreen(
                                    spaceId: space.id,
                                    spaceName: space.name,
                                  ),
                                ),
                              );
                              if (mounted) _load();
                            },
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
