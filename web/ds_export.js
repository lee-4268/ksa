/**
 * DS Excel Export
 * 방법 1 (고속): S3에서 원본 ZIP 다운로드 → ds_merge.js 로직으로 xlsx 생성
 * 방법 2 (폴백): DB 데이터 JSON → xlsx 생성
 * ds_merge.js의 전역 함수 재사용: _buildSheetXml, _buildFixedStylesXml,
 * _buildContentTypes, _buildWorkbook, _buildWorkbookRels, _buildRootRels,
 * _classifyDsFiles
 */

/**
 * S3에서 원본 ZIP 다운로드 → 병합 → xlsx 다운로드 (고속 경로)
 * @param {String} s3Url - presigned S3 GET URL
 * @param {String} metaJson - { divisionName, divisionCode, importDate, ... }
 * @param {Function} progressCallback - (stage, percent)
 * @param {Function} completionCallback - (success, message)
 * @param {String} authToken - Bearer auth token (optional)
 */
async function _exportDsFromS3(s3Url, metaJson, progressCallback, completionCallback, authToken) {
  try {
    progressCallback('S3에서 원본 파일 다운로드 중...', 3);

    var meta = JSON.parse(metaJson);

    // S3에서 ZIP 다운로드
    var fetchOpts = {};
    if (authToken) {
      fetchOpts.headers = { 'Authorization': 'Bearer ' + authToken };
    }
    var response = await fetch(s3Url, fetchOpts);
    if (!response.ok) {
      completionCallback(false, '파일 다운로드 실패: ' + response.status);
      return;
    }
    var zipArrayBuffer = await response.arrayBuffer();
    response = null;

    progressCallback('ZIP 압축 해제 중...', 8);

    var zip = await JSZip.loadAsync(zipArrayBuffer);
    zipArrayBuffer = null;

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

    progressCallback('파일 분류 중...', 10);
    var classified = _classifyDsFiles(xlsFiles);

    if (!classified.base) {
      completionCallback(false, '기본(base) DS 파일을 찾을 수 없습니다.');
      return;
    }

    // ========================================================
    // 컬럼 너비(preamble) 추출
    // ========================================================
    progressCallback('서식 정보 추출 중...', 12);

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

    // spt 시트 순서 + preamble
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

    // base + numbered
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

    // (100) 파일 → 일반사항(검사전)
    if (classified.skipped.length > 0) {
      progressCallback('(100) 파일 읽기...', 48);
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
    // xlsx 생성 (ds_merge.js와 동일)
    // ========================================================
    var xlsxZip = new JSZip();
    var totalSheets = sheetOrder.length;
    var totalRows = 0;

    for (var sheetIdx = 0; sheetIdx < totalSheets; sheetIdx++) {
      var currentSheet = sheetOrder[sheetIdx];
      progressCallback(currentSheet + ' 시트 생성 (' + (sheetIdx + 1) + '/' + totalSheets + ')',
        50 + Math.round((sheetIdx / totalSheets) * 40));

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

    progressCallback('메타데이터 생성 중...', 92);

    xlsxZip.file('[Content_Types].xml', _buildContentTypes(totalSheets));
    xlsxZip.file('_rels/.rels', _buildRootRels());
    xlsxZip.file('xl/workbook.xml', _buildWorkbook(sheetOrder));
    xlsxZip.file('xl/_rels/workbook.xml.rels', _buildWorkbookRels(totalSheets));
    xlsxZip.file('xl/styles.xml', _buildFixedStylesXml());

    progressCallback('파일 압축 중...', 95);

    var xlsxBlob = await xlsxZip.generateAsync({
      type: 'blob',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 }
    });
    xlsxZip = null;

    // 파일명: 본부명_날짜_DS.xlsx
    var divName = meta.divisionName || meta.divisionId || 'DS';
    var dateStr = meta.importDate || '';
    var outputName = divName + '_' + dateStr + '_DS.xlsx';

    // 다운로드 트리거
    var url = URL.createObjectURL(xlsxBlob);
    var a = document.createElement('a');
    a.href = url;
    a.download = outputName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    progressCallback('완료!', 100);

    completionCallback(true,
      outputName + ' 다운로드 완료\n'
      + totalSheets + '개 시트, ' + totalRows.toLocaleString() + '행\n'
      + '(컬럼 너비 + 원본 서식 유지)');

  } catch (e) {
    console.error('DS Export (S3) 오류:', e);
    completionCallback(false, 'Export 중 오류 발생: ' + e.message);
  }
}

/**
 * S3 presigned URL에서 xlsx 직접 다운로드 (pre-built xlsx 경로)
 * @param {String} url - presigned S3 GET URL (xlsx 파일)
 * @param {String} filename - 저장 파일명
 * @param {Function} progressCallback - (stage, percent)
 * @param {Function} completionCallback - (success, message)
 * @param {String} authToken - Bearer auth token (optional)
 */
async function _downloadXlsxFromUrl(url, filename, progressCallback, completionCallback, authToken) {
  try {
    progressCallback('xlsx 다운로드 중...', 20);

    var fetchOpts = {};
    if (authToken) {
      fetchOpts.headers = { 'Authorization': 'Bearer ' + authToken };
    }
    var response = await fetch(url, fetchOpts);
    if (!response.ok) {
      completionCallback(false, 'xlsx 다운로드 실패: ' + response.status);
      return;
    }

    progressCallback('파일 준비 중...', 80);

    var blob = await response.blob();

    var objUrl = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = objUrl;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(objUrl);

    progressCallback('완료!', 100);
    completionCallback(true, filename + ' 다운로드 완료');

  } catch (e) {
    console.error('xlsx 다운로드 오류:', e);
    completionCallback(false, '다운로드 오류: ' + e.message);
  }
}

/**
 * DB 데이터 JSON → xlsx 생성 + 다운로드 (폴백용 - S3에 원본이 없을 때)
 * @param {String} jsonString - { sheets: [{ name, headers, rows }], meta: { ... } }
 * @param {Function} progressCallback - (stage, percent)
 * @param {Function} completionCallback - (success, message)
 */
async function _exportDsToXlsx(jsonString, progressCallback, completionCallback) {
  try {
    progressCallback('데이터 준비 중...', 5);

    var parsed = JSON.parse(jsonString);
    var sheets = parsed.sheets;
    var meta = parsed.meta;

    if (!sheets || sheets.length === 0) {
      completionCallback(false, '내보낼 시트 데이터가 없습니다.');
      return;
    }

    var sheetNames = [];
    var sheetDataArrays = [];
    var totalRows = 0;

    for (var si = 0; si < sheets.length; si++) {
      var sheet = sheets[si];
      sheetNames.push(sheet.name);

      var data2d = [sheet.headers];
      for (var ri = 0; ri < sheet.rows.length; ri++) {
        data2d.push(sheet.rows[ri]);
      }
      sheetDataArrays.push(data2d);
      totalRows += sheet.rows.length;
      sheets[si] = null;
    }
    parsed = null;

    progressCallback('xlsx 생성 중...', 10);

    var xlsxZip = new JSZip();
    var totalSheets = sheetNames.length;

    for (var idx = 0; idx < totalSheets; idx++) {
      var pct = 10 + Math.round((idx / totalSheets) * 70);
      progressCallback(sheetNames[idx] + ' 시트 생성 (' + (idx + 1) + '/' + totalSheets + ')', pct);

      var sheetBlob = _buildSheetXml(sheetDataArrays[idx], '');
      xlsxZip.file('xl/worksheets/sheet' + (idx + 1) + '.xml', sheetBlob);
      sheetBlob = null;
      sheetDataArrays[idx] = null;

      await new Promise(function(resolve) { setTimeout(resolve, 5); });
    }
    sheetDataArrays = null;

    progressCallback('메타데이터 생성 중...', 82);

    xlsxZip.file('[Content_Types].xml', _buildContentTypes(totalSheets));
    xlsxZip.file('_rels/.rels', _buildRootRels());
    xlsxZip.file('xl/workbook.xml', _buildWorkbook(sheetNames));
    xlsxZip.file('xl/_rels/workbook.xml.rels', _buildWorkbookRels(totalSheets));
    xlsxZip.file('xl/styles.xml', _buildFixedStylesXml());

    progressCallback('파일 압축 중...', 88);

    var xlsxBlob = await xlsxZip.generateAsync({
      type: 'blob',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 }
    });
    xlsxZip = null;

    var divName = meta.divisionName || meta.divisionId || 'DS';
    var dateStr = meta.importDate || '';
    var outputName = divName + '_' + dateStr + '_DS.xlsx';

    var url = URL.createObjectURL(xlsxBlob);
    var a = document.createElement('a');
    a.href = url;
    a.download = outputName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    progressCallback('완료!', 100);

    completionCallback(true,
      outputName + ' 다운로드 완료\n'
      + totalSheets + '개 시트, ' + totalRows.toLocaleString() + '행');

  } catch (e) {
    console.error('DS Export 오류:', e);
    completionCallback(false, 'Export 중 오류 발생: ' + e.message);
  }
}
