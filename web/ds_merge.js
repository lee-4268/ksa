/**
 * DS 파일 병합 - 브라우저에서 SheetJS + JSZip으로 처리
 * 메모리 최적화: xlsx 수동 빌드 (시트별 XML 생성 → 데이터 즉시 해제)
 * 고정 서식: Arial 10pt, 가운데정렬, 헤더=회색배경(#BFBFBF)+볼드, 얇은 테두리
 */

// ============================================================
// SheetJS 관대한 읽기 헬퍼 (DIFAT 등 손상 xls 처리)
// ============================================================

function _xlsxRead(data, opts) {
  // ArrayBuffer → Uint8Array 변환 (type:'array'가 Uint8Array 전용이므로)
  var normalizedData = (data instanceof ArrayBuffer) ? new Uint8Array(data) : data;
  var normalizedOpts = (data instanceof ArrayBuffer)
    ? Object.assign({}, opts, { type: 'array' })
    : opts;

  // 1차: 일반 읽기
  try {
    return XLSX.read(normalizedData, normalizedOpts);
  } catch (e1) {
    // 2차: dense 모드 + sheetStubs로 재시도 (손상된 OLE2 구조 허용)
    try {
      var opts2 = Object.assign({}, normalizedOpts, { dense: true, sheetStubs: true });
      return XLSX.read(normalizedData, opts2);
    } catch (e2) {
      throw e1; // 모두 실패 시 원래 에러 throw
    }
  }
}

// ============================================================
// xlsx 수동 빌드 유틸리티
// ============================================================

function _colToRef(col) {
  var s = '';
  var c = col + 1;
  while (c > 0) {
    c--;
    s = String.fromCharCode(65 + (c % 26)) + s;
    c = Math.floor(c / 26);
  }
  return s;
}

function _escapeXml(val) {
  if (val == null) return '';
  var s = String(val);
  return s.replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;');
}

/**
 * 데이터 배열 → xlsx sheet XML Blob
 * 고정 서식: Arial 10pt, 가운데정렬, 헤더=회색배경+볼드
 * 5MB마다 Blob으로 플러시하여 JS 힙 메모리 최소화
 * @param {Array} data - 2D 배열 (헤더 포함)
 * @param {string} preamble - 컬럼 너비 XML (cols, sheetFormatPr 등)
 * @returns {Blob} sheet XML Blob
 */
function _buildSheetXml(data, preamble) {
  var parts = [];
  var partSize = 0;
  var blobs = [];

  parts.push('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
  parts.push('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    + ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">');

  if (preamble) {
    // 원본 XLS의 defaultRowHeight(229.5 등)가 행 높이를 오버라이드하므로 12.75로 강제
    preamble = preamble.replace(
      /(<sheetFormatPr[^>]*?)defaultRowHeight="[^"]*"/,
      '$1defaultRowHeight="12.75"'
    );
    parts.push(preamble);
  }

  parts.push('<sheetData>');

  for (var r = 0; r < data.length; r++) {
    var row = data[r];
    data[r] = null; // 메모리 해제

    if (!row) continue;

    var isHeader = (r === 0);
    // s="1"=데이터(Arial 10pt,가운데정렬,테두리), s="2"=헤더(+볼드+회색배경)
    var sAttr = isHeader ? ' s="2"' : ' s="1"';
    var rowXml = '<row r="' + (r + 1) + '" ht="12.75" customHeight="1">';

    for (var c = 0; c < row.length; c++) {
      var val = row[c];
      var ref = _colToRef(c) + (r + 1);

      if (val == null || val === '') {
        rowXml += '<c r="' + ref + '"' + sAttr + '/>';
      } else if (typeof val === 'number' && isFinite(val)) {
        rowXml += '<c r="' + ref + '"' + sAttr + '><v>' + val + '</v></c>';
      } else if (typeof val === 'boolean') {
        rowXml += '<c r="' + ref + '"' + sAttr + ' t="b"><v>' + (val ? 1 : 0) + '</v></c>';
      } else {
        rowXml += '<c r="' + ref + '"' + sAttr + ' t="inlineStr"><is><t>' + _escapeXml(val) + '</t></is></c>';
      }
    }
    rowXml += '</row>';
    parts.push(rowXml);
    partSize += rowXml.length;

    // 5MB마다 Blob으로 플러시 → JS 힙에서 해제
    if (partSize > 5000000) {
      blobs.push(new Blob(parts));
      parts = [];
      partSize = 0;
    }
  }

  parts.push('</sheetData></worksheet>');
  blobs.push(new Blob(parts));
  parts = null;

  return new Blob(blobs, { type: 'application/xml' });
}

/** 고정 styles.xml: Arial 10pt, 가운데정렬, 헤더=회색배경(#BFBFBF)+볼드, 얇은 테두리 */
function _buildFixedStylesXml() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    + '<fonts count="2">'
    +   '<font><sz val="10"/><name val="Arial"/></font>'
    +   '<font><b/><sz val="10"/><name val="Arial"/></font>'
    + '</fonts>'
    + '<fills count="3">'
    +   '<fill><patternFill patternType="none"/></fill>'
    +   '<fill><patternFill patternType="gray125"/></fill>'
    +   '<fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/></patternFill></fill>'
    + '</fills>'
    + '<borders count="2">'
    +   '<border><left/><right/><top/><bottom/><diagonal/></border>'
    +   '<border>'
    +     '<left style="thin"><color auto="1"/></left>'
    +     '<right style="thin"><color auto="1"/></right>'
    +     '<top style="thin"><color auto="1"/></top>'
    +     '<bottom style="thin"><color auto="1"/></bottom>'
    +     '<diagonal/>'
    +   '</border>'
    + '</borders>'
    + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    + '<cellXfs count="3">'
    +   '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    +   '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">'
    +     '<alignment horizontal="center" vertical="center" wrapText="1"/>'
    +   '</xf>'
    +   '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">'
    +     '<alignment horizontal="center" vertical="center" wrapText="1"/>'
    +   '</xf>'
    + '</cellXfs>'
    + '</styleSheet>';
}

function _buildContentTypes(sheetCount) {
  var xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  xml += '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">';
  xml += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>';
  xml += '<Default Extension="xml" ContentType="application/xml"/>';
  xml += '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>';
  xml += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>';
  for (var i = 1; i <= sheetCount; i++) {
    xml += '<Override PartName="/xl/worksheets/sheet' + i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>';
  }
  xml += '</Types>';
  return xml;
}

function _buildRootRels() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    + '</Relationships>';
}

function _buildWorkbook(sheetNames) {
  var xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  xml += '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">';
  xml += '<sheets>';
  for (var i = 0; i < sheetNames.length; i++) {
    xml += '<sheet name="' + _escapeXml(sheetNames[i]) + '" sheetId="' + (i + 1) + '" r:id="rId' + (i + 1) + '"/>';
  }
  xml += '</sheets></workbook>';
  return xml;
}

function _buildWorkbookRels(sheetCount) {
  var xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  xml += '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
  for (var i = 1; i <= sheetCount; i++) {
    xml += '<Relationship Id="rId' + i + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + i + '.xml"/>';
  }
  xml += '<Relationship Id="rId' + (sheetCount + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>';
  xml += '</Relationships>';
  return xml;
}


// ============================================================
// 파일 분류
// ============================================================

function _classifyDsFiles(fileNames) {
  var result = { base: null, numbered: [], spt: null, skipped: [] };

  for (var i = 0; i < fileNames.length; i++) {
    var fullPath = fileNames[i];
    var baseName = fullPath.split('/').pop();

    if (baseName.startsWith('.') || baseName.startsWith('__')) continue;
    if (!baseName.toLowerCase().endsWith('.xls')) continue;
    if (baseName.toLowerCase().endsWith('.xlsx')) continue;

    if (baseName.indexOf('(100)') !== -1) {
      result.skipped.push(fullPath);
      continue;
    }
    if (baseName.indexOf('_spt') !== -1) {
      result.spt = fullPath;
      continue;
    }
    var numMatch = baseName.match(/_(\d+)\.xls$/i);
    if (numMatch) {
      result.numbered.push({ name: fullPath, num: parseInt(numMatch[1]) });
      continue;
    }
    if (result.base === null) {
      result.base = fullPath;
    }
  }

  result.numbered.sort(function(a, b) { return a.num - b.num; });
  return result;
}


// ============================================================
// 메인 병합 함수
// ============================================================

async function _mergeDsFilesFromDart(zipArrayBuffer, progressCallback, completionCallback) {
  try {
    progressCallback('ZIP 압축 해제 중...', 3);

    // Dart GC로 인한 ArrayBuffer 무효화 방지: 즉시 복사
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

    console.log('DS 파일 분류:', classified);

    // ========================================================
    // 컬럼 너비(preamble) 추출: base → xlsx 변환 → 시트별 preamble
    // ========================================================
    progressCallback('서식 정보 추출 중...', 7);

    var baseBytes = await zip.files[classified.base].async('arraybuffer');
    var baseWb = _xlsxRead(baseBytes, { type: 'array', cellStyles: true });
    var sheetOrder = baseWb.SheetNames.slice();
    var baseSheetNames = baseWb.SheetNames.slice();

    progressCallback('서식 변환 중...', 8);
    var baseXlsxArr = XLSX.write(baseWb, { bookType: 'xlsx', type: 'array', bookSST: false });
    baseWb = null;
    baseBytes = null;

    var fmtZip = await JSZip.loadAsync(baseXlsxArr);
    baseXlsxArr = null;

    // 시트별 preamble(컬럼 너비 등) 추출
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

    // spt 시트 순서 + preamble 추출
    if (classified.spt) {
      var sptBytes2 = await zip.files[classified.spt].async('arraybuffer');
      var sptWb2 = _xlsxRead(sptBytes2, { type: 'array', cellStyles: true });
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

    // (100) → 모든 시트에 '(검사전)' 접미사 붙여서 추출
    var hundredSheetNames = [];
    if (classified.skipped.length > 0) {
      var hBytes = await zip.files[classified.skipped[0]].async('arraybuffer');
      var hWb = _xlsxRead(hBytes, { type: 'array', cellStyles: true });
      hundredSheetNames = hWb.SheetNames.slice();
      for (var hi = 0; hi < hundredSheetNames.length; hi++) {
        var hRenamedSheet = hundredSheetNames[hi] + '(검사전)';
        if (sheetOrder.indexOf(hRenamedSheet) === -1) {
          sheetOrder.push(hRenamedSheet);
        }
      }
      var hXlsxArr = XLSX.write(hWb, { bookType: 'xlsx', type: 'array', bookSST: false });
      hWb = null; hBytes = null;
      var hFmtZip = await JSZip.loadAsync(hXlsxArr);
      hXlsxArr = null;
      for (var hi2 = 0; hi2 < hundredSheetNames.length; hi2++) {
        var hSheetFile = 'xl/worksheets/sheet' + (hi2 + 1) + '.xml';
        var hRenamedSheet2 = hundredSheetNames[hi2] + '(검사전)';
        if (hFmtZip.files[hSheetFile] && !sheetFormats[hRenamedSheet2]) {
          var hXml = await hFmtZip.files[hSheetFile].async('string');
          var hPreambleMatch = hXml.match(/<worksheet[^>]*>([\s\S]*?)<sheetData/);
          sheetFormats[hRenamedSheet2] = hPreambleMatch ? hPreambleMatch[1].trim() : '';
          hXml = null;
        }
      }
      hFmtZip = null;
    }

    console.log('preamble 추출 완료:', Object.keys(sheetFormats));
    console.log('시트 목록:', sheetOrder);

    // ========================================================
    // 데이터 병합 (파일 단위로 한 번만 읽기 → 112회 → 16회로 최적화)
    // ========================================================
    var allMergedRows = {};
    for (var initSi = 0; initSi < sheetOrder.length; initSi++) {
      allMergedRows[sheetOrder[initSi]] = [];
    }

    // base + numbered 파일 (각 파일을 1회만 읽고 모든 시트 추출)
    var baseAndNumbered = [classified.base];
    for (var bni = 0; bni < classified.numbered.length; bni++) {
      baseAndNumbered.push(classified.numbered[bni].name);
    }

    for (var bfi = 0; bfi < baseAndNumbered.length; bfi++) {
      var bfName = baseAndNumbered[bfi];
      progressCallback('파일 읽기 (' + (bfi + 1) + '/' + baseAndNumbered.length + '): ' + bfName.split('/').pop(),
        10 + Math.round((bfi / baseAndNumbered.length) * 35));

      var bfData = await zip.files[bfName].async('arraybuffer');
      var bfWb = _xlsxRead(bfData, { type: 'array', cellDates: false });
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
        bfWb.Sheets[bsn] = null; // 시트 메모리 해제
      }
      bfWb = null;
      await new Promise(function(resolve) { setTimeout(resolve, 5); });
    }

    // spt 파일 (검사 시트 등 spt 고유 시트)
    if (classified.spt) {
      progressCallback('spt 파일 읽기...', 47);
      var sptFd = await zip.files[classified.spt].async('arraybuffer');
      var sptWbM = _xlsxRead(sptFd, { type: 'array', cellDates: false });
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

    // (100) 파일 → 모든 시트에 '(검사전)' 접미사 붙여서 병합
    if (classified.skipped.length > 0) {
      progressCallback('(100) 파일 읽기...', 48);
      for (var ski = 0; ski < classified.skipped.length; ski++) {
        var skFd = await zip.files[classified.skipped[ski]].async('arraybuffer');
        var skWbM = _xlsxRead(skFd, { type: 'array', cellDates: false });
        skFd = null;

        for (var sksi = 0; sksi < skWbM.SheetNames.length; sksi++) {
          var skOrigName = skWbM.SheetNames[sksi];
          var skRenamedName = skOrigName + '(검사전)';
          if (allMergedRows[skRenamedName] === undefined) continue;

          var skRowsM = XLSX.utils.sheet_to_json(skWbM.Sheets[skOrigName], { header: 1, raw: true, defval: '' });
          if (allMergedRows[skRenamedName].length === 0) {
            for (var sr3 = 0; sr3 < skRowsM.length; sr3++) allMergedRows[skRenamedName].push(skRowsM[sr3]);
          } else {
            for (var sr4 = 1; sr4 < skRowsM.length; sr4++) allMergedRows[skRenamedName].push(skRowsM[sr4]);
          }
          skRowsM = null;
          skWbM.Sheets[skOrigName] = null;
        }
        skWbM = null;
      }
    }

    // zip 원본 참조 해제 (더 이상 필요 없음)
    zip = null;

    // ========================================================
    // 시트 분할: 100만 행 초과 시 장치(1), 장치(2) 로 분할
    // ========================================================
    var MAX_ROWS_PER_SHEET = 1000000; // Excel 한도 1,048,576, 안전 여유
    var finalSheetOrder = [];   // 분할 후 실제 시트 순서
    var finalSheetData = {};    // 시트명 → rows
    var finalSheetFormats = {}; // 시트명 → preamble

    for (var si2 = 0; si2 < sheetOrder.length; si2++) {
      var sn = sheetOrder[si2];
      var rows = allMergedRows[sn];
      allMergedRows[sn] = null;

      if (!rows || rows.length === 0) continue;

      var header = rows[0];
      var dataRows = rows.length - 1; // 헤더 제외 데이터 행 수

      if (dataRows <= MAX_ROWS_PER_SHEET) {
        // 분할 불필요
        finalSheetOrder.push(sn);
        finalSheetData[sn] = rows;
        finalSheetFormats[sn] = sheetFormats[sn] || '';
      } else {
        // 분할 필요: 100만 행씩 청크
        var splitNum = 1;
        var offset = 1; // 헤더(row 0) 건너뜀
        while (offset < rows.length) {
          var chunk = [header].concat(rows.slice(offset, offset + MAX_ROWS_PER_SHEET));
          offset += MAX_ROWS_PER_SHEET;
          var splitName = sn + '(' + splitNum + ')';
          // Excel 시트명 31자 제한
          if (splitName.length > 31) splitName = splitName.substring(0, 31);
          finalSheetOrder.push(splitName);
          finalSheetData[splitName] = chunk;
          finalSheetFormats[splitName] = sheetFormats[sn] || '';
          splitNum++;
        }
        console.log('  시트 분할: ' + sn + ' → ' + (splitNum - 1) + '개 시트');
      }
      rows = null;
    }

    // ========================================================
    // 시트별 XML 생성 (데이터 사용 후 즉시 해제)
    // ========================================================
    var xlsxZip = new JSZip();
    var summaryParts = [];
    var totalSheets = finalSheetOrder.length;

    for (var sheetIdx = 0; sheetIdx < totalSheets; sheetIdx++) {
      var currentSheet = finalSheetOrder[sheetIdx];
      var pctBase = 50 + Math.round((sheetIdx / totalSheets) * 40);
      progressCallback(currentSheet + ' XML 생성 중 (' + (sheetIdx + 1) + '/' + totalSheets + ')', pctBase);

      var mergedRows = finalSheetData[currentSheet];
      finalSheetData[currentSheet] = null;

      var dataRowCount = mergedRows ? (mergedRows.length > 0 ? mergedRows.length - 1 : 0) : 0;
      summaryParts.push(currentSheet + ': ' + dataRowCount.toLocaleString() + '행');
      console.log('  ' + currentSheet + ': ' + dataRowCount.toLocaleString() + '행');

      if (mergedRows && mergedRows.length > 0) {
        var preamble = finalSheetFormats[currentSheet] || '';
        var sheetBlob = _buildSheetXml(mergedRows, preamble);
        xlsxZip.file('xl/worksheets/sheet' + (sheetIdx + 1) + '.xml', sheetBlob);
        sheetBlob = null;
      }

      mergedRows = null;
      await new Promise(function(resolve) { setTimeout(resolve, 10); });
    }

    console.log('병합 결과:', summaryParts.join(', '));
    progressCallback('xlsx 메타데이터 생성 중...', 92);

    // ========================================================
    // xlsx 메타데이터 추가
    // ========================================================
    xlsxZip.file('[Content_Types].xml', _buildContentTypes(totalSheets));
    xlsxZip.file('_rels/.rels', _buildRootRels());
    xlsxZip.file('xl/workbook.xml', _buildWorkbook(finalSheetOrder));
    xlsxZip.file('xl/_rels/workbook.xml.rels', _buildWorkbookRels(totalSheets));

    // styles.xml: 고정 서식 (Arial 10pt, 가운데정렬, 헤더=회색배경)
    xlsxZip.file('xl/styles.xml', _buildFixedStylesXml());

    progressCallback('xlsx 파일 압축 중...', 95);

    var xlsxBlob = await xlsxZip.generateAsync({
      type: 'blob',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 }
    });

    var baseFileName = classified.base.split('/').pop().replace('.xls', '');
    var outputName = baseFileName + '_통합.xlsx';

    var url = URL.createObjectURL(xlsxBlob);
    var a = document.createElement('a');
    a.href = url;
    a.download = outputName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    progressCallback('완료!', 100);

    var totalRows = 0;
    for (var ti = 0; ti < summaryParts.length; ti++) {
      var match = summaryParts[ti].match(/([\d,]+)행/);
      if (match) totalRows += parseInt(match[1].replace(/,/g, ''));
    }

    var resultMsg = '병합 완료! ' + outputName + '\n'
      + '시트 ' + totalSheets + '개, 총 ' + totalRows.toLocaleString() + '행'
      + (classified.skipped.length > 0 ? '\n(100) 일반사항 → 일반사항(검사전) 시트 포함' : '');
    completionCallback(true, resultMsg);

  } catch (e) {
    console.error('DS 파일 병합 오류:', e);
    completionCallback(false, '병합 중 오류 발생: ' + e.message);
  }
}
