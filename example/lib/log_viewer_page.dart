import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ipconnect_core/ipconnect_core.dart';

/// A page that displays V2Ray logs from the system logcat
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  List<String> _logs = [];
  List<String> _filteredLogs = [];
  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();
  final IpConnectCore _v2ray = IpConnectCore(onStatusChanged: (_) {});
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    // Schedule after current frame so ListView has dimensions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      _scrollController.animateTo(
        max,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadLogs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final logs = await _v2ray.getLogs();
      setState(() {
        _logs = logs;
        _filteredLogs = logs;
        _isLoading = false;
      });
      _scrollToEnd();
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading logs: $e')));
      }
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Clear Logs'),
            content: const Text('Are you sure you want to clear all logs?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      final success = await _v2ray.clearLogs();
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Logs cleared successfully')),
          );
          _loadLogs();
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Failed to clear logs')));
        }
      }
    }
  }

  Future<void> _copyLogs() async {
    if (_filteredLogs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No logs to copy')));
      return;
    }

    // Add log type prefixes to make copied logs more readable
    final formattedLogs =
        _filteredLogs.map((log) {
          if (log.contains('E/') ||
              log.toLowerCase().contains('error') ||
              log.toLowerCase().contains('exception')) {
            return '[ERROR] $log';
          } else if (log.contains('W/') || log.toLowerCase().contains('warn')) {
            return '[WARN] $log';
          } else {
            return '[INFO] $log';
          }
        }).toList();

    final logsText = formattedLogs.join('\n');
    await Clipboard.setData(ClipboardData(text: logsText));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_filteredLogs.length} log entries copied to clipboard',
          ),
        ),
      );
    }
  }

  void _filterLogs(String query) {
    if (query.isEmpty) {
      setState(() {
        _filteredLogs = _logs;
      });
    } else {
      setState(() {
        _filteredLogs =
            _logs
                .where((log) => log.toLowerCase().contains(query.toLowerCase()))
                .toList();
      });
    }
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('V2Ray Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyLogs,
            tooltip: 'Copy Logs',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogs,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearLogs,
            tooltip: 'Clear Logs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search logs...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon:
                    _searchController.text.isNotEmpty
                        ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _filterLogs('');
                          },
                        )
                        : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: _filterLogs,
            ),
          ),
          // Log count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Text(
                  'Total: ${_logs.length} logs',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_filteredLogs.length != _logs.length) ...[
                  const SizedBox(width: 8),
                  Text(
                    '(Filtered: ${_filteredLogs.length})',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Logs list
          Expanded(
            child:
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _filteredLogs.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.article_outlined,
                            size: 64,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _logs.isEmpty
                                ? 'No logs available'
                                : 'No logs match your search',
                            style: Theme.of(
                              context,
                            ).textTheme.bodyLarge?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_logs.isEmpty)
                            ElevatedButton.icon(
                              onPressed: _loadLogs,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh'),
                            ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom,
                      ),
                      itemCount: _filteredLogs.length,
                      itemBuilder: (context, index) {
                        final log = _filteredLogs[index];
                        final isError =
                            log.contains('E/') ||
                            log.toLowerCase().contains('error') ||
                            log.toLowerCase().contains('exception');
                        final isWarning =
                            log.contains('W/') ||
                            log.toLowerCase().contains('warn');

                        return Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outline.withValues(alpha: 0.2),
                              ),
                            ),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              isError
                                  ? Icons.error_outline
                                  : isWarning
                                  ? Icons.warning_amber_outlined
                                  : Icons.info_outline,
                              size: 16,
                              color:
                                  isError
                                      ? Colors.red
                                      : isWarning
                                      ? Colors.orange
                                      : Colors.blue,
                            ),
                            title: Text(
                              log,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color:
                                    isError
                                        ? Colors.red.shade300
                                        : isWarning
                                        ? Colors.orange.shade300
                                        : null,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}
