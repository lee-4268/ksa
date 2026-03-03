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
  final ScrollController _hScrollController = ScrollController();

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
    _hScrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    // 탭 전환 시 수평 스크롤 리셋
    if (_hScrollController.hasClients) {
      _hScrollController.jumpTo(0);
    }
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
      setState(() {});
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
        divisionCode: widget.divisionCode,
      );

      if (!mounted) return;

      setState(() {
        if (loadMore && existing != null) {
          existing.items.addAll(page.items);
          existing.lastKey = page.lastEvaluatedKey;
          existing.hasMore = page.hasMore;
          existing.isLoadingMore = false;
          _mergeNewHeaders(existing, page.items);
        } else {
          final data = _SheetData(
            items: page.items,
            lastKey: page.lastEvaluatedKey,
            hasMore: page.hasMore,
            searchQuery: _activeSearch,
          );
          // 서버 제공 헤더 사용 (컬럼 순서 + 빈 컬럼 보장)
          if (page.headers != null && page.headers!.isNotEmpty) {
            data.headers = page.headers!;
          } else {
            _inferHeaders(data);
          }
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

  /// 서버 헤더 없을 때: 데이터에서 헤더 추론
  void _inferHeaders(_SheetData data) {
    final headers = <String>[];
    final seen = <String>{};
    for (final item in data.items) {
      for (final key in item.data.keys) {
        if (seen.add(key)) headers.add(key);
      }
    }
    data.headers = headers;
  }

  /// 추가 로드 시: 기존 헤더에 없는 새 컬럼만 append
  void _mergeNewHeaders(_SheetData data, List<DsRecord> newItems) {
    final existing = data.headers.toSet();
    for (final item in newItems) {
      for (final key in item.data.keys) {
        if (existing.add(key)) data.headers.add(key);
      }
    }
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

    return Column(
      children: [
        // 수평 스크롤 가능한 데이터 영역
        Expanded(
          child: Scrollbar(
            controller: _hScrollController,
            thumbVisibility: true,
            trackVisibility: true,
            child: SingleChildScrollView(
              controller: _hScrollController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _calcTableWidth(headers.length),
                child: _buildFixedHeaderTable(headers, records),
              ),
            ),
          ),
        ),
        // 좌우 스크롤 힌트
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          color: Colors.grey.shade50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.swipe, size: 14, color: Colors.grey.shade400),
              const SizedBox(width: 4),
              Text('좌우로 스크롤하여 더 많은 컬럼 보기',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
            ],
          ),
        ),
      ],
    );
  }

  double _calcTableWidth(int colCount) {
    // # 열(50) + 각 데이터 열(130) + 여백
    return 50.0 + colCount * 130.0 + 32.0;
  }

  /// 고정 헤더 + 스크롤 가능한 데이터 영역
  Widget _buildFixedHeaderTable(List<String> headers, List<DsRecord> records) {
    return Column(
      children: [
        // 고정 헤더 행
        Container(
          color: Colors.grey.shade200,
          child: Row(
            children: [
              _buildHeaderCell('#', width: 50),
              ...headers.map((h) => _buildHeaderCell(h, width: 130)),
            ],
          ),
        ),
        // 스크롤 가능한 데이터 행
        Expanded(
          child: ListView.builder(
            itemCount: records.length,
            itemBuilder: (context, idx) {
              final record = records[idx];
              return Container(
                decoration: BoxDecoration(
                  color: idx.isOdd ? Colors.grey.shade50 : Colors.white,
                  border: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 0.5)),
                ),
                child: Row(
                  children: [
                    _buildDataCell('${idx + 1}', width: 50, isIndex: true),
                    ...headers.map((h) {
                      final val = record.data[h] ?? '';
                      final isMatch = _activeSearch.isNotEmpty &&
                          val.toLowerCase().contains(_activeSearch.toLowerCase());
                      return _buildDataCell(val, width: 130, highlight: isMatch);
                    }),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderCell(String text, {required double width}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildDataCell(String text, {required double width, bool isIndex = false, bool highlight = false}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isIndex ? Colors.grey.shade500 : Colors.black87,
          backgroundColor: highlight ? Colors.yellow.shade200 : null,
        ),
        overflow: TextOverflow.ellipsis,
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
