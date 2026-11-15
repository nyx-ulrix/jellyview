import 'dart:async';

import 'package:flutter/material.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'package:fladder/providers/deluge_provider.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/sliver_list_padding.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';

/// Hand-written route (build_runner can't run on this toolchain); mirrors the generated ones.
class GetRoute extends PageRouteInfo<void> {
  const GetRoute({List<PageRouteInfo>? children}) : super(GetRoute.name, initialChildren: children);

  static const String name = 'GetRoute';

  static PageInfo page = PageInfo(name, builder: (data) => const GetScreen());
}

/// The media-stack dashboard inside the app: find and request titles, watch the download queue,
/// see what airs this week. Same layout language as the rest of JellyView (rows, neutral chips, one red action).
class GetScreen extends ConsumerStatefulWidget {
  const GetScreen({super.key});

  @override
  ConsumerState<GetScreen> createState() => _GetScreenState();
}

class _GetScreenState extends ConsumerState<GetScreen> {
  final searchController = TextEditingController();
  Timer? poll;

  List<Map<String, dynamic>>? results;
  List<Map<String, dynamic>> queue = [];
  List<Map<String, dynamic>> upcoming = [];
  List<Map<String, dynamic>> recent = [];
  Map<String, dynamic>? pause;
  String? error;
  bool searching = false;

  DelugeApi get api => ref.read(delugeApiProvider);

  @override
  void initState() {
    super.initState();
    refresh();
    // ponytail: fixed 5 s poll while the tab is open; a push channel if the server ever grows one
    poll = Timer.periodic(const Duration(seconds: 5), (_) => refreshQueue());
  }

  @override
  void dispose() {
    poll?.cancel();
    searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    await Future.wait([
      refreshQueue(),
      // Already-downloaded episodes aren't "coming up" any more.
      _load(() async => upcoming = (await api.upcoming()).where((u) => u['have'] != true).toList()),
      _load(() async => recent = await api.recent()),
    ]);
  }

  Future<void> refreshQueue() => _load(() async {
        final q = await api.queue();
        final p = await api.pauseState();
        // Something left the queue (finished or cancelled): refresh "Recently added".
        if (q.length < queue.length) api.recent().then((r) => mounted ? setState(() => recent = r) : null).ignore();
        queue = q;
        pause = p;
      });

  Future<void> _load(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> runSearch(String q) async {
    if (q.trim().isEmpty) return setState(() => results = null);
    setState(() => searching = true);
    await _load(() async => results = await api.search(q.trim()));
    if (mounted) setState(() => searching = false);
  }

  void toast(String text) => ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  Future<void> act(Future<void> Function() action, String done) async {
    try {
      await action();
      toast(done);
      await refreshQueue();
    } catch (e) {
      toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Tap on a "Coming up" episode: search the trackers for it (and any other aired, missing episode of that season).
  Future<void> searchUpcoming(Map<String, dynamic> u) async {
    final air = DateTime.tryParse(u['air'] ?? '')?.toLocal();
    if (u['have'] == true) return toast('${u['ep']} is already downloaded');
    if (air != null && air.isAfter(DateTime.now())) {
      return toast("${u['ep']} isn't out yet. It downloads automatically once it airs.");
    }
    final id = u['seriesId'];
    if (id is! int) {
      // Older dashboard without seriesId: show the title's search result instead.
      searchController.text = u['title'] ?? '';
      return runSearch(searchController.text);
    }
    var found = 0;
    await act(
        () async =>
            found = ((await api.missing('show', id, season: u['season'] as int?))['episodes'] as num? ?? 0).toInt(),
        'Searching for ${u['title']} ${u['ep']}');
    if (found == 0) toast('No release found to search for yet. Try again later.');
  }

  /// Opens a page of the dashboard in an in-app browser panel (Chrome Custom Tab) over JellyView.
  Future<void> openDashboardPage(String page) async {
    final base = ref.read(delugeUrlProvider);
    final uri = Uri.tryParse('$base/#$page');
    if (base.isEmpty || uri == null) return editUrl();
    if (!await launcher.launchUrl(uri, mode: launcher.LaunchMode.inAppBrowserView)) {
      toast("Couldn't open the dashboard.");
    }
  }

  Future<void> editUrl() async {
    final controller = TextEditingController(text: ref.read(delugeUrlProvider));
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Media server address'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'https://wehavedelugeathome.<tailnet>.ts.net'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (url == null) return;
    saveDelugeUrl(ref, url);
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(delugeUrlProvider, (_, __) => refresh());
    final padding = AdaptiveLayout.adaptivePadding(context);
    final wide = MediaQuery.sizeOf(context).width > 900;
    final theme = Theme.of(context);

    final header = Row(
      spacing: 8,
      children: [
        Expanded(
          child: SearchBar(
            controller: searchController,
            hintText: 'Find a movie or show to get',
            leading: const Icon(IconsaxPlusLinear.search_normal_1),
            elevation: const WidgetStatePropertyAll(0),
            shape: WidgetStatePropertyAll(FladderTheme.smallShape),
            textInputAction: TextInputAction.search,
            onSubmitted: runSearch,
            trailing: [
              if (searching)
                const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              else if (results != null)
                IconButton(
                  tooltip: 'Clear',
                  onPressed: () {
                    searchController.clear();
                    setState(() => results = null);
                  },
                  icon: const Icon(IconsaxPlusLinear.close_circle),
                ),
            ],
          ),
        ),
        if (pause != null && (pause!['paused'] == true || (pause!['unfinished'] ?? 0) > 0))
          FilledButton.tonalIcon(
            onPressed: () => act(() async => pause = await api.setPaused(pause!['paused'] != true),
                pause!['paused'] == true ? 'Downloads resumed' : 'Downloads paused'),
            icon: Icon(pause!['paused'] == true ? IconsaxPlusLinear.play : IconsaxPlusLinear.pause, size: 18),
            label: Text(pause!['paused'] == true ? 'Resume all' : 'Pause all'),
          ),
        // The dashboard's other pages (upgrade quality, missing subtitles, delete...) open over the app.
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(IconsaxPlusLinear.more_square),
          onSelected: (page) => openDashboardPage(page),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'library', child: Text('Manage library (upgrade, subtitles, delete)')),
            PopupMenuItem(value: 'downloading', child: Text('Downloading')),
            PopupMenuItem(value: 'added', child: Text('Added recently')),
          ],
        ),
        IconButton(tooltip: 'Media server address', onPressed: editUrl, icon: const Icon(IconsaxPlusLinear.setting_2)),
      ],
    );

    final main = <Widget>[
      if (error != null) _ErrorCard(message: error!, onRetry: refresh, onEdit: editUrl),
      if (results != null) ...[
        _Heading(results!.isEmpty ? 'Nothing found' : 'Results'),
        for (final r in results!) _ResultRow(item: r, api: api, onDone: refreshQueue),
      ] else ...[
        _Heading('Downloading', trailing: queue.isEmpty ? null : '${queue.length}'),
        if (queue.isEmpty && error == null) const _Empty('Nothing downloading. Search above to get something.'),
        for (final q in queue)
          _QueueRow(
            item: q,
            onPause: () => act(() => api.itemAction(q['hash'], 'pause'), 'Paused'),
            onResume: () => act(() => api.itemAction(q['hash'], 'resume'), 'Resumed'),
            onCancel: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Cancel ${q['title']}?'),
                  content: const Text('The download stops and its partial file is removed.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancel download')),
                  ],
                ),
              );
              if (ok == true) await act(() => api.cancel(hash: q['hash']), 'Download cancelled');
            },
          ),
      ],
    ];

    final side = <Widget>[
      const _Heading('Coming up', trailing: 'Next 7 days'),
      if (upcoming.isEmpty) const _Empty('Nothing airing this week.'),
      for (final u in upcoming) _UpcomingRow(item: u, onTap: () => searchUpcoming(u)),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 16),
        const _Heading('Recently added'),
        for (final r in recent) _RecentRow(item: r),
      ],
    ];

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: PullToRefresh(
        onRefresh: refresh,
        child: (context) => CustomScrollView(
          controller: AdaptiveLayout.scrollOf(context, HomeTabs.get),
          slivers: [
            const DefaultSliverTopBadding(),
            SliverPadding(
              // On phones DefaultSliverTopBadding adds nothing, so clear the status bar here.
              padding: padding.copyWith(
                  top: 16 +
                      (AdaptiveLayout.viewSizeOf(context) == ViewSize.phone ? MediaQuery.paddingOf(context).top : 0),
                  bottom: 16),
              sliver: SliverToBoxAdapter(child: header),
            ),
            SliverPadding(
              padding: padding,
              sliver: SliverToBoxAdapter(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 32,
                        children: [
                          Expanded(
                              flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: main)),
                          Expanded(
                              flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: side)),
                        ],
                      )
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...main, ...side]),
              ),
            ),
            const DefaultSliverBottomPadding(),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final String? trailing;
  const _Heading(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text(text, style: theme.textTheme.titleLarge)),
          if (trailing != null)
            Text(trailing!, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  const _ErrorCard({required this.message, required this.onRetry, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: FladderTheme.smallShape.borderRadius,
      ),
      child: Row(
        spacing: 12,
        children: [
          Icon(IconsaxPlusLinear.cloud_cross, color: theme.colorScheme.onSurfaceVariant),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text("Can't reach the media server", style: theme.textTheme.titleMedium),
                Text('Check Tailscale is on. $message',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          TextButton(onPressed: onEdit, child: const Text('Address')),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;
  final double width;
  const _Poster(this.url, {this.width = 64});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: FladderTheme.smallShape.borderRadius,
      child: SizedBox(
        width: width,
        height: width * 1.5,
        child: url == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: const Icon(IconsaxPlusLinear.video_square),
              )
            // Placeholder tile behind the art so a slow/blocked image host never leaves a hole in the row.
            : ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Image.network(
                  url!,
                  fit: BoxFit.cover,
                  width: width,
                  height: width * 1.5,
                  cacheWidth: (width * 3).round(),
                  errorBuilder: (context, _, __) => const Icon(IconsaxPlusLinear.video_square),
                ),
              ),
      ),
    );
  }
}

const _scopes = {'all': 'All episodes', 'latest': 'Latest season', 'future': 'New episodes only'};

class _ResultRow extends StatefulWidget {
  final Map<String, dynamic> item;
  final DelugeApi api;
  final VoidCallback onDone;
  const _ResultRow({required this.item, required this.api, required this.onDone});

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  String scope = 'all';
  bool uhd = false;
  bool busy = false;
  String? status;

  Map<String, dynamic> get x => widget.item;
  bool get isShow => x['kind'] == 'show';
  bool get tracked => x['have'] == true && x['monitored'] == true;

  Future<void> get() async {
    setState(() => busy = true);
    try {
      String? size;
      try {
        final est = await widget.api.estimate(x['kind'], x['id'], scope, uhd);
        final total = est['total'];
        if (total is num && total > 0) size = formatBytes(total);
      } catch (_) {/* no estimate: just go */}
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Get ${x['title']}?'),
          content: Text([
            if (isShow) _scopes[scope],
            uhd ? '4K' : '1080p',
            if (size != null) 'about $size',
          ].join(' · ')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Get')),
          ],
        ),
      );
      if (ok != true) return;
      final res = await widget.api
          .request(x['kind'], x['id'], anime: x['anime'] == true, scope: isShow ? scope : null, uhd: uhd);
      setState(() => status =
          res['again'] == true ? 'Searching again' : (scope == 'future' ? 'Tracking new episodes' : 'Requested'));
      widget.onDone();
    } catch (e) {
      setState(() => status = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final meta = [
      isShow ? 'Show' : 'Movie',
      if (x['year'] != null) '${x['year']}',
      if (isShow && x['seasons'] != null) '${x['seasons']} season${x['seasons'] == 1 ? '' : 's'}',
      if (x['by'] != null) x['by'],
      if (x['anime'] == true) 'Anime',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          _Poster(x['poster']),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(x['title'] ?? '',
                    style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(meta, style: muted),
                if ((x['overview'] ?? '').isNotEmpty)
                  Text(x['overview'], style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (x['have'] == true)
                      Chip(
                        avatar: const Icon(IconsaxPlusLinear.tick_circle, size: 16),
                        label: Text(!isShow
                            ? 'In library'
                            : (x['files'] ?? 0) == 0
                                ? 'Added, waiting for episodes'
                                : '${x['files']} episodes in library'),
                      ),
                    if (isShow && !tracked)
                      PopupMenuButton<String>(
                        tooltip: 'Which episodes',
                        initialValue: scope,
                        onSelected: (v) => setState(() => scope = v),
                        itemBuilder: (context) => [
                          for (final e in _scopes.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        child: Chip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 6,
                            children: [Text(_scopes[scope]!), const Icon(IconsaxPlusLinear.arrow_down_1, size: 16)],
                          ),
                        ),
                      ),
                    FilterChip(
                      label: const Text('4K'),
                      selected: uhd,
                      onSelected: (v) => setState(() => uhd = v),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : get,
                      icon: busy
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(IconsaxPlusLinear.add_circle, size: 18),
                      label: Text(x['have'] == true ? 'Get again' : 'Get'),
                    ),
                    if (status != null) Text(status!, style: muted),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  const _QueueRow({required this.item, required this.onPause, required this.onResume, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final progress = (item['progress'] as num? ?? 0).toDouble().clamp(0.0, 1.0);
    final qstate = '${item['qstate'] ?? ''}';
    final paused = item['heldPaused'] == true || qstate.contains('paused') || qstate.contains('stopped');
    final speed = item['speed'] as num? ?? 0;
    final eta = formatEta(item['eta'] as String?);
    final state = '${item['state'] ?? ''}'.toLowerCase();
    final waiting = switch (qstate) {
      _ when state.startsWith('import') => 'Importing to library',
      'queuedDL' => 'Queued',
      'stalledDL' => 'Waiting for peers',
      'metaDL' || 'forcedMetaDL' => 'Getting file info',
      'checkingDL' || 'checkingResumeData' => 'Checking',
      _ => null,
    };
    final seeds = item['seeds'] as num?;
    final line = [
      '${(progress * 100).round()}%',
      if (paused) 'Paused' else if (speed > 0) '${formatBytes(speed)}/s' else if (waiting != null) waiting,
      if (!paused && seeds != null && speed > 0) '$seeds ${seeds == 1 ? 'seed' : 'seeds'}',
      if (!paused && eta != null) '$eta left',
      if (item['size'] is num && item['size'] > 0) formatBytes(item['size']),
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        spacing: 16,
        children: [
          _Poster(item['poster'], width: 44),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(item['title'] ?? '',
                    style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                if ((item['detail'] ?? '').isNotEmpty)
                  Text(item['detail'], style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  color: paused ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                Text(item['problem'] ?? line,
                    style: item['problem'] != null ? muted?.copyWith(color: theme.colorScheme.error) : muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if ((item['hash'] ?? '').isNotEmpty) ...[
            IconButton(
              tooltip: paused ? 'Resume' : 'Pause',
              onPressed: paused ? onResume : onPause,
              icon: Icon(paused ? IconsaxPlusLinear.play : IconsaxPlusLinear.pause),
            ),
            IconButton(tooltip: 'Cancel', onPressed: onCancel, icon: const Icon(IconsaxPlusLinear.trash)),
          ],
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _RecentRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final date = DateTime.tryParse(item['date'] ?? '')?.toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        spacing: 12,
        children: [
          _Poster(item['poster'], width: 36),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(item['title'] ?? '',
                    style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                    [
                      if ((item['detail'] ?? '').isNotEmpty) item['detail'],
                      if ((item['quality'] ?? '').isNotEmpty) item['quality'],
                    ].join('  ·  '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (date != null) Text(_ago(date), style: muted),
        ],
      ),
    );
  }

  static String _ago(DateTime date) {
    final d = DateTime.now().difference(date);
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _UpcomingRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  const _UpcomingRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final air = DateTime.tryParse(item['air'] ?? '')?.toLocal();
    final when = air == null ? '' : MaterialLocalizations.of(context).formatShortMonthDay(air);
    final time = air == null ? '' : TimeOfDay.fromDateTime(air).format(context);
    return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            spacing: 12,
            children: [
              _Poster(item['poster'], width: 36),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(item['title'] ?? '',
                        style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text([item['ep'], if ((item['name'] ?? '').isNotEmpty) item['name']].join('  ·  '),
                        style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(when, style: theme.textTheme.labelLarge),
                  Text(item['have'] == true ? 'Downloaded' : time, style: muted),
                ],
              ),
            ],
          ),
        ));
  }
}
