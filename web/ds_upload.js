/**
 * DS 파일 업로드용 브라우저 파싱 - SheetJS + JSZip
 * ds_merge.js의 파싱 로직 재활용, xlsx 생성 대신 JSON 청크 콜백
 * 지역코드/날짜 자동 추출 → Dart에서 EC2로 청크 업로드
 */

// 전파관리소 지역코드 → 회사 본부 매핑
// 수도권(10) → 4개 본부 통합, 충남(50)+충북(55) → 충청, 전남(30)+전북(70) → 서부
var DS_REGION_CODE_MAP = {
  '10': { divisionId: 'sudogwon', divisionName: '수도권' },
  '20': { divisionId: 'gyeongnam', divisionName: '경남본부' },
  '30': { divisionId: 'seobu', divisionName: '서부본부' },
  '40': { divisionId: 'gangwon', divisionName: '강원본부' },
  '50': { divisionId: 'chungcheong', divisionName: '충청본부' },
  '55': { divisionId: 'chungcheong', divisionName: '충청본부' },
  '60': { divisionId: 'gyeongbuk', divisionName: '경북본부' },
  '70': { divisionId: 'seobu', divisionName: '서부본부' }
};

/**
 * 파일명에서 지역코드와 날짜 추출
 * 예: SKT(50)20260203.xls → { regionCode: '50', importDate: '20260203' }
 */
function _parseDsFileName(fileName) {
  var codeMatch = fileName.match(/\((\d+)\)/);
  var dateMatch = fileName.match(/(\d{8})/);
  return {
    regionCode: codeMatch ? codeMatch[1] : null,
    importDate: dateMatch ? dateMatch[1] : null
  };
}

/**
 * DS ZIP 파싱 → 시트별 JSON 청크 콜백
 * @param {ArrayBuffer} zipArrayBuffer - ZIP 파일 바이트
 * @param {Function} chunkCallback - (jsonString) 청크 데이터 (Dart에서 EC2로 전송)
 * @param {Function} progressCallback - (stage, percent) 진행률
 * @param {Function} completionCallback - (success, message, metaJson) 완료
 */
/**
 * DS ZIP 파싱 → 시트별 JSON 청크 콜백 (스트리밍 방식)
 *
 * ★ 메모리 최적화: 파일을 하나씩 읽고 즉시 청크 전송 후 메모리 해제
 *   기존 방식(allMergedRows 전체 누적)은 1.8M행+ 파일에서 브라우저 OOM 발생
 *   개선: 파일 1개 읽기 → 즉시 스트리밍 → 해제 → 다음 파일
 *   최대 메모리 사용 = 단일 파일 크기 (전체 아님)
 */
async function _parseDsForUpload(zipArrayBuffer, chunkCallback, progressCallback, completionCallback) {
  try {
    progressCallback('ZIP 압축 해제 중...', 3);

    var zipCopy = zipArrayBuffer.slice(0);
    var zip = await JSZip.loadAsync(zipCopy);
    zipCopy = null;

    var allFiles = Object.keys(zip.files).filter(function(name) {
      return !zip.files[name].dir;
    });
    var xlsFiles = allFiles.filter(function(name) {
      var lower = name.toLowerCase();
      return lower.endsWith('.xls') && !lower.endsWith('.xlsx');
    });

    if (xlsFiles.length === 0) {
      completionCallback(false, 'ZIP 파일 안에 .xls 파일이 없습니다.', '');
      return;
    }

    progressCallback('파일 분류 중...', 5);
    var classified = _classifyDsFiles(xlsFiles);

    if (!classified.base) {
      completionCallback(false, '기본(base) DS 파일을 찾을 수 없습니다.', '');
      return;
    }

    var baseName = classified.base.split('/').pop();
    var parsed = _parseDsFileName(baseName);

    if (!parsed.regionCode || !parsed.importDate) {
      completionCallback(false, '파일명에서 지역코드 또는 날짜를 추출할 수 없습니다: ' + baseName, '');
      return;
    }

    var regionInfo = DS_REGION_CODE_MAP[parsed.regionCode];
    if (!regionInfo) {
      completionCallback(false, '알 수 없는 지역코드: ' + parsed.regionCode, '');
      return;
    }

    var meta = {
      divisionId: regionInfo.divisionId,
      divisionName: regionInfo.divisionName,
      divisionCode: parsed.regionCode,
      importDate: parsed.importDate,
      fileName: baseName
    };

    console.log('DS 파일 메타:', meta);

    // ========================================================
    // 스트리밍 상태
    // ========================================================
    var CHUNK_SIZE = 500;
    var sheetOrder = [];       // 최종 시트 순서
    var sheetHeaders = {};     // 시트별 헤더 배열 (첫 행)
    var sheetStats = {};       // 시트별 누적 데이터 행수
    var sheetStartIndex = {};  // 시트별 현재 startIndex (파일 간 연속성)
    var totalRows = 0;

    function registerSheet(name) {
      if (sheetOrder.indexOf(name) === -1) {
        sheetOrder.push(name);
        sheetStats[name] = 0;
        sheetStartIndex[name] = 0;
      }
    }

    /**
     * 시트 행 배열(헤더 포함)을 청크로 분할해 Dart에 즉시 전달
     * 메모리 절약: rows를 함수 내부에서 null로 해제
     */
    async function streamSheetRows(sheetName, rows) {
      var dataRows = rows.slice(1); // 헤더 행(index 0) 스킵 → 데이터만
      rows = null;
      if (!dataRows || dataRows.length === 0) { dataRows = null; return; }

      var headers = sheetHeaders[sheetName];
      var dataCount = dataRows.length;
      var totalChunks = Math.ceil(dataCount / CHUNK_SIZE) || 1;
      var startIdx = sheetStartIndex[sheetName]; // 이 시트의 현재 전역 시작 인덱스

      console.log('  [stream] ' + sheetName + ': +' + dataCount.toLocaleString() + '행 (startIdx=' + startIdx + ')');

      for (var ci = 0; ci < totalChunks; ci++) {
        var start = ci * CHUNK_SIZE;
        var end = Math.min(start + CHUNK_SIZE, dataCount);
        var chunkRows = dataRows.slice(start, end);

        var chunk = JSON.stringify({
          divisionId: meta.divisionId,
          divisionCode: meta.divisionCode,
          importDate: meta.importDate,
          sheetName: sheetName,
          headers: headers,
          rows: chunkRows,
          chunkIndex: ci,
          totalChunks: totalChunks,
          startIndex: startIdx + start  // 전역 행 인덱스 (파일 간 연속)
        });

        chunkCallback(chunk);
        chunkRows = null;
        chunk = null;

        await new Promise(function(resolve) { setTimeout(resolve, 2); });
      }

      // 다음 파일에서 이 시트를 이어받을 위치 갱신
      sheetStartIndex[sheetName] += dataCount;
      sheetStats[sheetName] += dataCount;
      totalRows += dataCount;
      dataRows = null;
    }

    // ========================================================
    // 1. base 파일: 시트 구조 확정 + 헤더 추출 + 즉시 스트리밍
    //    (파일 1회 읽기 - 구조 분석과 데이터 전송 동시 처리)
    // ========================================================
    progressCallback('base 파일 읽기 중...', 8);

    var baseBytes = await zip.files[classified.base].async('arraybuffer');
    var baseWb = XLSX.read(baseBytes, { type: 'array', cellDates: false });
    baseBytes = null;

    var baseSheetNames = baseWb.SheetNames.slice();

    for (var bsi = 0; bsi < baseSheetNames.length; bsi++) {
      var bsn = baseSheetNames[bsi];
      registerSheet(bsn);

      var bRows = XLSX.utils.sheet_to_json(baseWb.Sheets[bsn], { header: 1, raw: true, defval: '' });
      baseWb.Sheets[bsn] = null; // 시트 즉시 해제

      sheetHeaders[bsn] = (bRows[0] || []).map(function(h) { return String(h); });

      progressCallback('base: ' + bsn + ' 전송 중... (' + (bsi + 1) + '/' + baseSheetNames.length + ')',
        8 + Math.round((bsi / baseSheetNames.length) * 17));

      await streamSheetRows(bsn, bRows);
    }
    baseWb = null;

    // ========================================================
    // 2. numbered 파일: base 시트에 행 추가 (즉시 스트리밍)
    //    부적합무선국은 numbered 파일에서 추가하지 않음
    // ========================================================
    for (var nfi = 0; nfi < classified.numbered.length; nfi++) {
      var nfName = classified.numbered[nfi].name;
      progressCallback(
        '번호파일 읽기 (' + (nfi + 1) + '/' + classified.numbered.length + '): ' + nfName.split('/').pop(),
        27 + Math.round((nfi / Math.max(classified.numbered.length, 1)) * 38)
      );

      var nfData = await zip.files[nfName].async('arraybuffer');
      var nfWb = XLSX.read(nfData, { type: 'array', cellDates: false });
      nfData = null;

      for (var nsi = 0; nsi < baseSheetNames.length; nsi++) {
        var nsn = baseSheetNames[nsi];
        if (nfWb.SheetNames.indexOf(nsn) === -1) continue;

        // 부적합무선국: base 파일에서만 (numbered에서는 추가 안 함)
        if (nsn === '부적합무선국') { nfWb.Sheets[nsn] = null; continue; }

        var nRows = XLSX.utils.sheet_to_json(nfWb.Sheets[nsn], { header: 1, raw: true, defval: '' });
        nfWb.Sheets[nsn] = null;

        await streamSheetRows(nsn, nRows);
      }
      nfWb = null;
      await new Promise(function(resolve) { setTimeout(resolve, 5); });
    }

    // ========================================================
    // 3. spt 파일: base에 없는 새 시트만 (즉시 스트리밍)
    // ========================================================
    if (classified.spt) {
      progressCallback('spt 파일 읽기...', 67);

      var sptFd = await zip.files[classified.spt].async('arraybuffer');
      var sptWb = XLSX.read(sptFd, { type: 'array', cellDates: false });
      sptFd = null;

      for (var ssi = 0; ssi < sptWb.SheetNames.length; ssi++) {
        var ssn = sptWb.SheetNames[ssi];
        // base 시트는 spt에서 스킵 (이미 처리됨)
        if (baseSheetNames.indexOf(ssn) !== -1) { sptWb.Sheets[ssn] = null; continue; }

        registerSheet(ssn);

        var sRows = XLSX.utils.sheet_to_json(sptWb.Sheets[ssn], { header: 1, raw: true, defval: '' });
        sptWb.Sheets[ssn] = null;

        sheetHeaders[ssn] = (sRows[0] || []).map(function(h) { return String(h); });
        await streamSheetRows(ssn, sRows);
      }
      sptWb = null;
    }

    // ========================================================
    // 4. (100) 파일 → '일반사항(검사전)' 시트 (즉시 스트리밍)
    // ========================================================
    if (classified.skipped.length > 0) {
      registerSheet('일반사항(검사전)');
      sheetHeaders['일반사항(검사전)'] = sheetHeaders['일반사항(검사전)'] || [];

      for (var ski = 0; ski < classified.skipped.length; ski++) {
        progressCallback('(100) 파일 읽기 (' + (ski + 1) + '/' + classified.skipped.length + ')...', 85);

        var skFd = await zip.files[classified.skipped[ski]].async('arraybuffer');
        var skWb = XLSX.read(skFd, { type: 'array', cellDates: false });
        skFd = null;

        if (skWb.SheetNames.indexOf('일반사항') !== -1) {
          var skRows = XLSX.utils.sheet_to_json(skWb.Sheets['일반사항'], { header: 1, raw: true, defval: '' });
          skWb.Sheets['일반사항'] = null;

          // 첫 번째 파일에서만 헤더 추출
          if (sheetHeaders['일반사항(검사전)'].length === 0) {
            sheetHeaders['일반사항(검사전)'] = (skRows[0] || []).map(function(h) { return String(h); });
          }
          await streamSheetRows('일반사항(검사전)', skRows);
        }
        skWb = null;
      }
    }

    zip = null;
    progressCallback('완료!', 100);

    meta.sheetStats = sheetStats;
    meta.totalRows = totalRows;
    meta.sheetOrder = sheetOrder;

    console.log('DS 파싱 완료: ' + sheetOrder.length + '개 시트, ' + totalRows.toLocaleString() + '행');

    completionCallback(true,
      regionInfo.divisionName + ' ' + parsed.importDate + '\n'
      + sheetOrder.length + '개 시트, ' + totalRows.toLocaleString() + '행 파싱 완료',
      JSON.stringify(meta));

  } catch (e) {
    console.error('DS 파싱 오류:', e);
    completionCallback(false, '파싱 중 오류 발생: ' + e.message, '');
  }
}

/**
 * DS ZIP → 병합 xlsx 생성 → S3 PUT (업로드 시 pre-built xlsx 저장)
 * ds_export.js의 _exportDsFromS3와 동일한 로직이나 S3 업로드로 마무리
 * @param {ArrayBuffer} zipArrayBuffer - 원본 ZIP ArrayBuffer
 * @param {String} xlsxPutUrl - S3 presigned PUT URL for xlsx
 * @param {String} metaJson - { divisionId, divisionCode, divisionName, importDate }
 * @param {Function} progressCallback - (stage, percent)
 * @param {Function} completionCallback - (success, message)
 */
async function _buildDsXlsxAndUploadToS3(zipArrayBuffer, xlsxPutUrl, metaJson, progressCallback, completionCallback) {
  try {
    progressCallback('xlsx 생성 준비 중...', 2);
    console.log('xlsx 생성 시작:', metaJson);

    var zipCopy = zipArrayBuffer.slice(0);
    var zip = await JSZip.loadAsync(zipCopy);
    zipCopy = null;

    var allFiles = Object.keys(zip.files).filter(function(name) {
      return !zip.files[name].dir;
    });
    var xlsFiles = allFiles.filter(function(name) {
      var lower = name.toLowerCase();
      return lower.endsWith('.xls') && !lower.endsWith('.xlsx');
    });

    if (xlsFiles.length === 0) {
      completionCallback(false, 'ZIP 파일 안에 .xls 파일이 없습니다.');
      return;
    }

    progressCallback('파일 분류 중...', 5);
    var classified = _classifyDsFiles(xlsFiles);

    if (!classified.base) {
      completionCallback(false, '기본(base) DS 파일을 찾을 수 없습니다.');
      return;
    }

    // ========================================================
    // 컬럼 너비(preamble) 추출
    // ========================================================
    progressCallback('서식 정보 추출 중...', 8);

    var baseBytes = await zip.files[classified.base].async('arraybuffer');
    var baseWb = XLSX.read(baseBytes, { type: 'array', cellStyles: true });
    var sheetOrder = baseWb.SheetNames.slice();
    var baseSheetNames = baseWb.SheetNames.slice();

    var baseXlsxArr = XLSX.write(baseWb, { bookType: 'xlsx', type: 'array', bookSST: false });
    baseWb = null;
    baseBytes = null;

    var fmtZip = await JSZip.loadAsync(baseXlsxArr);
    baseXlsxArr = null;

    var sheetFormats = {};
    for (var si = 0; si < baseSheetNames.length; si++) {
      var sName = baseSheetNames[si];
      var sheetFile = 'xl/worksheets/sheet' + (si + 1) + '.xml';
      if (fmtZip.files[sheetFile]) {
        var xml = await fmtZip.files[sheetFile].async('string');
        var preambleMatch = xml.match(/<worksheet[^>]*>([\s\S]*?)<sheetData/);
        sheetFormats[sName] = preambleMatch ? preambleMatch[1].trim() : '';
        xml = null;
      }
    }
    fmtZip = null;

    // spt preamble
    if (classified.spt) {
      var sptBytes2 = await zip.files[classified.spt].async('arraybuffer');
      var sptWb2 = XLSX.read(sptBytes2, { type: 'array', cellStyles: true });
      var sptSheetNames2 = sptWb2.SheetNames.slice();
      for (var si2 = 0; si2 < sptSheetNames2.length; si2++) {
        if (sheetOrder.indexOf(sptSheetNames2[si2]) === -1) {
          sheetOrder.push(sptSheetNames2[si2]);
        }
      }
      var sptXlsxArr = XLSX.write(sptWb2, { bookType: 'xlsx', type: 'array', bookSST: false });
      sptWb2 = null; sptBytes2 = null;
      var sptFmtZip = await JSZip.loadAsync(sptXlsxArr);
      sptXlsxArr = null;
      for (var si3 = 0; si3 < sptSheetNames2.length; si3++) {
        var sptSheetFile = 'xl/worksheets/sheet' + (si3 + 1) + '.xml';
        if (sptFmtZip.files[sptSheetFile] && !sheetFormats[sptSheetNames2[si3]]) {
          var sptXml = await sptFmtZip.files[sptSheetFile].async('string');
          var sptPreambleMatch = sptXml.match(/<worksheet[^>]*>([\s\S]*?)<sheetData/);
          sheetFormats[sptSheetNames2[si3]] = sptPreambleMatch ? sptPreambleMatch[1].trim() : '';
          sptXml = null;
        }
      }
      sptFmtZip = null;
    }

    // (100) → 일반사항(검사전) preamble
    if (classified.skipped.length > 0) {
      sheetOrder.push('일반사항(검사전)');
      var hBytes = await zip.files[classified.skipped[0]].async('arraybuffer');
      var hWb = XLSX.read(hBytes, { type: 'array', cellStyles: true });
      var hXlsxArr = XLSX.write(hWb, { bookType: 'xlsx', type: 'array', bookSST: false });
      hWb = null; hBytes = null;
      var hFmtZip = await JSZip.loadAsync(hXlsxArr);
      hXlsxArr = null;
      var hSheetFile = 'xl/worksheets/sheet1.xml';
      if (hFmtZip.files[hSheetFile]) {
        var hXml = await hFmtZip.files[hSheetFile].async('string');
        var hPreambleMatch = hXml.match(/<worksheet[^>]*>([\s\S]*?)<sheetData/);
        sheetFormats['일반사항(검사전)'] = hPreambleMatch ? hPreambleMatch[1].trim() : '';
        hXml = null;
      }
      hFmtZip = null;
    }

    // ========================================================
    // 데이터 병합
    // ========================================================
    var allMergedRows = {};
    for (var initSi = 0; initSi < sheetOrder.length; initSi++) {
      allMergedRows[sheetOrder[initSi]] = [];
    }

    var baseAndNumbered = [classified.base];
    for (var bni = 0; bni < classified.numbered.length; bni++) {
      baseAndNumbered.push(classified.numbered[bni].name);
    }

    for (var bfi = 0; bfi < baseAndNumbered.length; bfi++) {
      var bfName = baseAndNumbered[bfi];
      progressCallback('파일 읽기 (' + (bfi + 1) + '/' + baseAndNumbered.length + '): ' + bfName.split('/').pop(),
        15 + Math.round((bfi / baseAndNumbered.length) * 30));

      var bfData = await zip.files[bfName].async('arraybuffer');
      var bfWb = XLSX.read(bfData, { type: 'array', cellDates: false });
      bfData = null;

      for (var bsi = 0; bsi < baseSheetNames.length; bsi++) {
        var bsn = baseSheetNames[bsi];
        if (bfWb.SheetNames.indexOf(bsn) === -1) continue;

        var bRows = XLSX.utils.sheet_to_json(bfWb.Sheets[bsn], { header: 1, raw: true, defval: '' });
        if (allMergedRows[bsn].length === 0) {
          for (var br = 0; br < bRows.length; br++) allMergedRows[bsn].push(bRows[br]);
        } else if (bsn !== '부적합무선국') {
          for (var br2 = 1; br2 < bRows.length; br2++) allMergedRows[bsn].push(bRows[br2]);
        }
        bRows = null;
        bfWb.Sheets[bsn] = null;
      }
      bfWb = null;
      await new Promise(function(resolve) { setTimeout(resolve, 5); });
    }

    // spt 파일
    if (classified.spt) {
      progressCallback('spt 파일 읽기...', 47);
      var sptFd = await zip.files[classified.spt].async('arraybuffer');
      var sptWbM = XLSX.read(sptFd, { type: 'array', cellDates: false });
      sptFd = null;

      for (var ssi = 0; ssi < sptWbM.SheetNames.length; ssi++) {
        var ssn = sptWbM.SheetNames[ssi];
        if (baseSheetNames.indexOf(ssn) !== -1) continue;
        if (allMergedRows[ssn] === undefined) continue;

        var sRows = XLSX.utils.sheet_to_json(sptWbM.Sheets[ssn], { header: 1, raw: true, defval: '' });
        for (var sri = 0; sri < sRows.length; sri++) allMergedRows[ssn].push(sRows[sri]);
        sRows = null;
      }
      sptWbM = null;
    }

    // (100) → 일반사항(검사전)
    if (classified.skipped.length > 0) {
      progressCallback('(100) 파일 읽기...', 49);
      for (var ski = 0; ski < classified.skipped.length; ski++) {
        var skFd = await zip.files[classified.skipped[ski]].async('arraybuffer');
        var skWbM = XLSX.read(skFd, { type: 'array', cellDates: false });
        skFd = null;

        if (skWbM.SheetNames.indexOf('일반사항') !== -1) {
          var skRowsM = XLSX.utils.sheet_to_json(skWbM.Sheets['일반사항'], { header: 1, raw: true, defval: '' });
          if (allMergedRows['일반사항(검사전)'].length === 0) {
            for (var sr3 = 0; sr3 < skRowsM.length; sr3++) allMergedRows['일반사항(검사전)'].push(skRowsM[sr3]);
          } else {
            for (var sr4 = 1; sr4 < skRowsM.length; sr4++) allMergedRows['일반사항(검사전)'].push(skRowsM[sr4]);
          }
          skRowsM = null;
        }
        skWbM = null;
      }
    }

    zip = null;

    // ========================================================
    // xlsx 생성
    // ========================================================
    var xlsxZip = new JSZip();
    var totalSheets = sheetOrder.length;
    var totalRows = 0;

    for (var sheetIdx = 0; sheetIdx < totalSheets; sheetIdx++) {
      var currentSheet = sheetOrder[sheetIdx];
      progressCallback(currentSheet + ' 시트 생성 (' + (sheetIdx + 1) + '/' + totalSheets + ')',
        52 + Math.round((sheetIdx / totalSheets) * 36));

      var mergedRows = allMergedRows[currentSheet];
      allMergedRows[currentSheet] = null;

      if (mergedRows && mergedRows.length > 0) {
        totalRows += Math.max(0, mergedRows.length - 1);
        var preamble = sheetFormats[currentSheet] || '';
        var sheetBlob = _buildSheetXml(mergedRows, preamble);
        xlsxZip.file('xl/worksheets/sheet' + (sheetIdx + 1) + '.xml', sheetBlob);
        sheetBlob = null;
      }
      mergedRows = null;

      await new Promise(function(resolve) { setTimeout(resolve, 5); });
    }
    allMergedRows = null;

    progressCallback('메타데이터 생성 중...', 90);

    xlsxZip.file('[Content_Types].xml', _buildContentTypes(totalSheets));
    xlsxZip.file('_rels/.rels', _buildRootRels());
    xlsxZip.file('xl/workbook.xml', _buildWorkbook(sheetOrder));
    xlsxZip.file('xl/_rels/workbook.xml.rels', _buildWorkbookRels(totalSheets));
    xlsxZip.file('xl/styles.xml', _buildFixedStylesXml());

    progressCallback('파일 압축 중...', 92);

    var xlsxBlob = await xlsxZip.generateAsync({
      type: 'blob',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 }
    });
    xlsxZip = null;

    // ========================================================
    // S3 PUT 업로드
    // ========================================================
    progressCallback('S3에 xlsx 업로드 중...', 96);

    var putResp = await fetch(xlsxPutUrl, {
      method: 'PUT',
      body: xlsxBlob,
      headers: { 'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
    });
    xlsxBlob = null;

    if (!putResp.ok) {
      completionCallback(false, 'S3 xlsx 업로드 실패: ' + putResp.status);
      return;
    }

    progressCallback('완료!', 100);
    completionCallback(true,
      'xlsx S3 업로드 완료 (' + totalSheets + '개 시트, ' + totalRows.toLocaleString() + '행)');

  } catch (e) {
    console.error('xlsx S3 업로드 오류:', e);
    completionCallback(false, 'xlsx 생성 중 오류: ' + e.message);
  }
}
