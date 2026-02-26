import 'dart:async';

import 'package:flutter/material.dart';
import '../services/ds_data_service.dart';

/// DS 데이터 조회 화면 - 시트별 탭 + 데이터 테이블 + 서버 검색 + 페이징
class DsDataScreen extends StatefulWidget {
  final String divisionId;
  final String divisionName;
  final String importDate;
  final String divisionCode;
  final Map<String, int> sheetStats;

  const DsDataScreen({
    super.key,
    required this.divisionId,
    required this.divisionName,
    required this.importDate,
    required this.divisionCode,
    required this.sheetStats,
  });

  @override
  State<DsDataScreen> createState() => _DsDataScreenState();
}

class _DsDataScreenState extends State<DsDataScreen> with SingleTickerProviderStateMixin {
  static const Color _accentColor = Color(0xFF5C6BC0);
  static const int _pageSize = 100;

  final DsDataService _dataService = DsDataService();
  final TextEditingController _searchController = TextEditingController();

  late TabController _tabController;
  late List<String> _sheetNames;

  // 시트별 데이터 캐시
  final Map<String, _SheetData> _sheetCache = {};

  // 서버 검색
  String _activeSearch = '';
  Timer? _debounce;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _sheetNames = widget.sheetStats.keys.toList();
    _tabController = TabController(length: _sheetNames.length, vsync: this);
    _tabController.addListener(_onTabChanged);

    if (_sheetNames.isNotEmpty) {
      _loadSheetData(_sheetNames.first);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final sheet = _sheetNames[_tabController.index];
    final cacheKey = _cacheKey(sheet);
    if (!_sheetCache.containsKey(cacheKey)) {
      _loadSheetData(sheet);
    }
  }

  String _cacheKey(String sheetName) => '$sheetName|$_activeSearch';

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.isEmpty && _activeSearch.isEmpty) return;

    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _activeSearch = value;
        _isSearching = value.isNotEmpty;
      });
      // 현재 탭의 데이터를 새 검색어로 다시 로드
      final sheet = _sheetNames[_tabController.index];
      _loadSheetData(sheet);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _debounce?.cancel();
    setState(() {
      _activeSearch = '';
      _isSearching = false;
    });
    final sheet = _sheetNames[_tabController.index];
    final cacheKey = _cacheKey(sheet);
    if (!_sheetCache.containsKey(cacheKey)) {
      _loadSheetData(sheet);
    } else {
      setState(() {}); // rebuild with cached non-search data
    }
  }

  Future<void> _loadSheetData(String sheetName, {bool loadMore = false}) async {
    final cacheKey = _cacheKey(sheetName);
    final existing = _sheetCache[cacheKey];

    if (!loadMore) {
      setState(() {
        _sheetCache[cacheKey] = _SheetData(isLoading: true, searchQuery: _activeSearch);
      });
    } else if (existing != null) {
      setState(() {
        existing.isLoadingMore = true;
      });
    }

    try {
      final page = await _dataService.getData(
        divisionId: widget.divisionId,
        sheetName: sheetName,
        importDate: widget.importDate,
        limit: _pageSize,
        lastKey: loadMore ? existing?.lastKey : null,
        search: _activeSearch.isNotEmpty ? _activeSearch : null,
      );

      if (!mounted) return;

      setState(() {
        if (loadMore && existing != null) {
          existing.items.addAll(page.items);
          existing.lastKey = page.lastEvaluatedKey;
          existing.hasMore = page.hasMore;
          existing.isLoadingMore = false;
          _updateHeaders(existing);
        } else {
          final data = _SheetData(
            items: page.items,
            lastKey: page.lastEvaluatedKey,
            hasMore: page.hasMore,
            searchQuery: _activeSearch,
          );
          _updateHeaders(data);
          _sheetCache[cacheKey] = data;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sheetCache[cacheKey] = _SheetData(
          error: e.toString().replaceFirst('Exception: ', ''),
          searchQuery: _activeSearch,
        );
      });
    }
  }

  void _updateHeaders(_SheetData data) {
    final headers = <String>{};
    for (final item in data.items) {
      headers.addAll(item.data.keys);
    }
    data.headers = headers.toList();
  }

  @override
  Widget build(BuildContext context) {
    final formattedDate = widget.importDate.length == 8
        ? '${widget.importDate.substring(0, 4)}-${widget.importDate.substring(4, 6)}-${widget.importDate.substring(6, 8)}'
        : widget.importDate;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: Text('${widget.divisionName} $formattedDate'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        bottom: _sheetNames.length > 1
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                labelColor: _accentColor,
                unselectedLabelColor: Colors.grey.shade500,
                indicatorColor: _accentColor,
                tabAlignment: TabAlignment.start,
                tabs: _sheetNames.map((name) {
                  final count = widget.sheetStats[name] ?? 0;
                  return Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(name),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            DsDataService.formatNumber(count),
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              )
            : null,
      ),
      body: _sheetNames.isEmpty
          ? const Center(child: Text('시트 데이터가 없습니다'))
          : Column(
              children: [
                _buildSearchBar(),
                Expanded(
                  child: _sheetNames.length > 1
                      ? TabBarView(
                          controller: _tabController,
                          children: _sheetNames.map((name) => _buildSheetView(name)).toList(),
                        )
                      : _buildSheetView(_sheetNames.first),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '전체 데이터에서 검색 (Enter 또는 0.5초 후 자동 검색)',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _activeSearch.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _clearSearch,
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: (v) {
                _debounce?.cancel();
                if (v == _activeSearch) return;
                setState(() {
                  _activeSearch = v;
                  _isSearching = v.isNotEmpty;
                });
                final sheet = _sheetNames[_tabController.index];
                _loadSheetData(sheet);
              },
            ),
          ),
          if (_isSearching) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_outlined, size: 14, color: _accentColor),
                  const SizedBox(width: 4),
                  Text('서버 검색', style: TextStyle(fontSize: 11, color: _accentColor, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSheetView(String sheetName) {
    final cacheKey = _cacheKey(sheetName);
    final data = _sheetCache[cacheKey];

    if (data == null || data.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (data.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 40, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text(data.error!, style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _loadSheetData(sheetName),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }

    if (data.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              _isSearching ? '"$_activeSearch" 검색 결과가 없습니다' : '데이터가 없습니다',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 정보 바
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.grey.shade100,
          child: Row(
            children: [
              Text(
                _isSearching
                    ? '검색 결과: ${DsDataService.formatNumber(data.items.length)}건'
                    : '${DsDataService.formatNumber(data.items.length)}건 로드됨'
                        '  |  전체: ${DsDataService.formatNumber(widget.sheetStats[sheetName] ?? 0)}건',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const Spacer(),
              if (data.hasMore)
                TextButton.icon(
                  onPressed: data.isLoadingMore ? null : () => _loadSheetData(sheetName, loadMore: true),
                  icon: data.isLoadingMore
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add, size: 16),
                  label: Text(data.isLoadingMore ? '로딩 중...' : '더 보기'),
                ),
            ],
          ),
        ),
        // 데이터 테이블
        Expanded(
          child: _buildDataTable(data.headers, data.items),
        ),
      ],
    );
  }

  Widget _buildDataTable(List<String> headers, List<DsRecord> records) {
    if (headers.isEmpty || records.isEmpty) {
      return const Center(child: Text('데이터가 없습니다'));
    }

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
            headingTextStyle: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.black87,
            ),
            dataTextStyle: const TextStyle(fontSize: 12, color: Colors.black87),
            columnSpacing: 16,
            horizontalMargin: 16,
            columns: [
              const DataColumn(label: Text('#', style: TextStyle(fontWeight: FontWeight.bold))),
              ...headers.map((h) => DataColumn(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(h, overflow: TextOverflow.ellipsis),
                    ),
                  )),
            ],
            rows: records.asMap().entries.map((entry) {
              final idx = entry.key;
              final record = entry.value;
              return DataRow(
                color: WidgetStateProperty.resolveWith<Color?>(
                  (states) => idx.isOdd ? Colors.grey.shade50 : null,
                ),
                cells: [
                  DataCell(Text('${idx + 1}',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 11))),
                  ...headers.map((h) {
                    final val = record.data[h] ?? '';
                    final isMatch = _activeSearch.isNotEmpty &&
                        val.toLowerCase().contains(_activeSearch.toLowerCase());
                    return DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          val,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            backgroundColor: isMatch ? Colors.yellow.shade200 : null,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _SheetData {
  List<DsRecord> items;
  List<String> headers;
  String? lastKey;
  bool hasMore;
  bool isLoading;
  bool isLoadingMore;
  String? error;
  String searchQuery;

  _SheetData({
    List<DsRecord>? items,
    this.headers = const [],
    this.lastKey,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
    this.searchQuery = '',
  }) : items = items ?? [];
}
