import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/providers/deluge_provider.dart';

/// The dashboard's Library page, native: every show and movie on the drive, with tracking, quality,
/// subtitles and delete. Filters match the dashboard's (Incomplete, Tracked, Not tracked, Can upgrade, No subtitles).
class GetLibraryScreen extends ConsumerStatefulWidget {
  const GetLibraryScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GetLibraryScreen()));

  @override
  ConsumerState<GetLibraryScreen> createState() => _GetLibraryScreenState();
}

enum _Filter { all, incomplete, tracked, untracked, upgrade, nosubs }

extension on _Filter {
  String get label => switch (this) {
        _Filter.all => 'All',
        _Filter.incomplete => 'Incomplete',
        _Filter.tracked => 'Tracked',
        _Filter.untracked => 'Not tracked',
        _Filter.upgrade => 'Can upgrade',
        _Filter.nosubs => 'No subtitles',
      };
}

class _GetLibraryScreenState extends ConsumerState<GetLibraryScreen> {
  bool showsTab = true;
  _Filter filter = _Filter.all;
  List<Map<String, dynamic>> shows = [];
  List<Map<String, dynamic>> movies = [];
  bool loading = true;
  String? error;

  DelugeApi get api => ref.read(delugeApiProvider);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await Future.wait([api.shows(), api.movies()]);
      if (!mounted) return;
      setState(() {
        shows = results[0];
        movies = results[1];
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> act(Future<dynamic> Function() call, String done) async {
    try {
      await call();
      toast(done);
      await load();
    } catch (e) {
      toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  bool _matches(Map<String, dynamic> x) {
    final isShow = showsTab;
    final have = isShow ? (x['have'] ?? 0) as num : ((x['have'] == true) ? 1 : 0);
    final aired = isShow ? (x['aired'] ?? 0) as num : 1;
    final lowres = x['lowres'] == true || (x['lowres'] is num && (x['lowres'] as num) > 0);
    final below4k = (x['below4k'] ?? 0) as num;
    return switch (filter) {
      _Filter.all => true,
      _Filter.incomplete => have < aired,
      _Filter.tracked => x['monitored'] == true,
      _Filter.untracked => x['monitored'] != true,
      _Filter.upgrade => lowres || (x['uhd'] == true && below4k > 0),
      _Filter.nosubs => ((x['subsMissing'] ?? 0) as num) > 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = (showsTab ? shows : movies).where(_matches).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Manage library')),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text('Shows (${shows.length})')),
                  ButtonSegment(value: false, label: Text('Movies (${movies.length})')),
                ],
                selected: {showsTab},
                onSelectionChanged: (v) => setState(() => showsTab = v.first),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                spacing: 8,
                children: [
                  for (final f in _Filter.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: filter == f,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => filter = f),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (loading && shows.isEmpty && movies.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else if (error != null)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!, style: TextStyle(color: theme.colorScheme.error)))
            else if (items.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Nothing here.')))
            else
              for (final x in items) _LibraryRow(item: x, isShow: showsTab, state: this),
          ],
        ),
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isShow;
  final _GetLibraryScreenState state;
  const _LibraryRow({required this.item, required this.isShow, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final kind = isShow ? 'show' : 'movie';
    final id = item['id'] as int;
    final title = '${item['title']}';
    final tracked = item['monitored'] == true;
    final uhd = item['uhd'] == true;
    final noUpgrade = ((item['noUpgrade'] ?? 0) as num) > 0;
    final lowres = item['lowres'] == true || (item['lowres'] is num && (item['lowres'] as num) > 0);
    final subsMissing = ((item['subsMissing'] ?? 0) as num) > 0;
    final have = item['have'];
    final aired = item['aired'];
    final detail = [
      if (item['year'] != null) '${item['year']}',
      if (isShow) '$have of $aired episodes' else (have == true ? 'Downloaded' : 'Not downloaded'),
      formatBytes((item['size'] ?? 0) as num),
    ].join(' · ');
    final api = state.api;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 66,
          child: item['poster'] != null
              ? Image.network('${item['poster']}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox())
              : ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(detail, style: muted),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (isShow && tracked) const _Tag('Tracked'),
              if (uhd) const _Tag('4K'),
              if (lowres && !noUpgrade) const _Tag('Can upgrade'),
              if (subsMissing) const _Tag('No subtitles'),
            ],
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz),
        onSelected: (action) async {
          switch (action) {
            case 'track':
              await state.act(() => api.track(id, !tracked), tracked ? 'Stopped tracking $title' : 'Tracking $title');
            case 'missing':
              await state.act(() => api.missing('show', id), 'Searching for missing episodes of $title');
            case 'upgrade':
              await state.act(() => api.upgrade(kind, id), 'Looking for a better copy of $title');
            case 'noupgrade':
              await state.act(() => api.noUpgrade(kind, id), "$title won't be upgraded");
            case 'allowupgrade':
              await state.act(() => api.allowUpgrades(kind, id), '$title can be upgraded again');
            case 'get4k':
              await state.act(() => api.get4k(kind, id), 'Looking for the 4K copy of $title');
            case 'uhd':
              await state.act(() => api.setUhd(kind, id, !uhd), uhd ? '$title set to 1080p' : '$title set to 4K');
            case 'subs':
              await state.act(() => api.subtitles(kind, id), 'Looking for subtitles for $title');
            case 'delete':
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Delete $title?'),
                  content: const Text('This removes the files from the drive. It cannot be undone.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) await state.act(() => api.delete(kind, id), 'Deleted $title');
          }
        },
        itemBuilder: (context) => [
          if (isShow)
            PopupMenuItem(
              value: 'track',
              child: Text(tracked ? 'Stop tracking (no new episodes)' : 'Track (get new episodes)'),
            ),
          if (isShow && (item['have'] ?? 0) < (item['aired'] ?? 0))
            const PopupMenuItem(value: 'missing', child: Text('Get missing episodes')),
          if (lowres && !noUpgrade) const PopupMenuItem(value: 'upgrade', child: Text('Upgrade quality')),
          PopupMenuItem(
            value: noUpgrade ? 'allowupgrade' : 'noupgrade',
            child: Text(noUpgrade ? 'Allow upgrades again' : "Don't upgrade (keep this copy)"),
          ),
          if (uhd && ((item['below4k'] ?? 0) as num) > 0)
            const PopupMenuItem(value: 'get4k', child: Text('Get the 4K copy now')),
          PopupMenuItem(value: 'uhd', child: Text(uhd ? 'Switch to 1080p' : 'Switch to 4K')),
          if (subsMissing) const PopupMenuItem(value: 'subs', child: Text('Find subtitles')),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              spacing: 8,
              children: [
                Icon(IconsaxPlusLinear.trash, color: Theme.of(context).colorScheme.error, size: 20),
                Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}
