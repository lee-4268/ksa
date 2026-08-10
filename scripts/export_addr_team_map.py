#!/usr/bin/env python3
"""주소 → 품질개선팀 매핑 로직을 xlsx로 내보낸다.

매핑 규칙(상수/함수)은 yolov8/api/routers/inspection.py 소스에서 직접 추출해 실행하므로
코드가 바뀌면 결과물도 자동으로 따라간다(별도 복사본 유지 불필요).

사용법:
  python scripts/export_addr_team_map.py                       # 서울 확정규칙만 반영
  python scripts/export_addr_team_map.py -l /tmp/learned_addr_map.json
  python scripts/export_addr_team_map.py -l /tmp/cert_cache.db   # EC2에서 직접 학습
  python scripts/export_addr_team_map.py -o docs/주소-팀_매핑.xlsx --with-ri
"""
import argparse
import ast
import json
import os
import sqlite3
import sys
import tempfile
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSPECTION_PY = ''
LEGAL_DONG_TSV = ''

# 로컬 리포지토리 / EC2 배포본(APP_DIR) 양쪽에서 동작
API_DIR_CANDIDATES = [
    os.path.join(ROOT, 'yolov8', 'api'),
    os.environ.get('APP_DIR', '/home/ubuntu/kca-api'),
]


def resolve_paths(api_dir):
    """inspection.py 와 legal_dong_code.tsv 를 각각 탐색.

    배포본에는 deploy_backend.sh 가 코드만 복사하고 tsv 는 런타임 자산으로 남아 있어
    두 파일이 다른 위치에 있을 수 있으므로 따로 찾는다.
    """
    global INSPECTION_PY, LEGAL_DONG_TSV
    # --api-dir 를 명시했으면 폴백하지 않는다 (오타를 조용히 넘기지 않도록)
    cands = [api_dir] if api_dir else API_DIR_CANDIDATES

    for d in cands:
        p = os.path.join(d, 'routers', 'inspection.py')
        if os.path.exists(p):
            INSPECTION_PY = p
            break
    else:
        sys.exit('inspection.py 를 찾지 못했습니다. --api-dir 로 지정하세요.\n'
                 f'  탐색: {", ".join(cands)}')

    for d in cands:
        p = os.path.join(d, 'legal_dong_code.tsv')
        if os.path.exists(p):
            LEGAL_DONG_TSV = p
            break
    else:
        sys.exit('legal_dong_code.tsv 를 찾지 못했습니다.\n'
                 f'  탐색: {", ".join(cands)}\n'
                 '  저장소 yolov8/api/legal_dong_code.tsv 를 해당 위치에 두거나 '
                 '--api-dir 로 지정하세요.')

    return os.path.dirname(os.path.dirname(INSPECTION_PY))

WANT_CONSTS = [
    'INSP_ORG_MAP', 'INSP_TEAM_TO_HDQT', '_VALID_SKT_HDQTS', '_ACCESS_TO_SKT_HDQT',
    '_DEPRECATED_TEAM_MAP', '_SEOUL_GU_TO_TEAM', '_SEOUL_GU_SORTED', '_ADDR_ABBR_MAP',
]
WANT_FUNCS = ['_normalize_addr', '_hdqt_from_addr', '_normalize_skt_hdqt',
              '_normalize_learned_map', '_learn_addr_map_from_cert_db']


def load_logic():
    """inspection.py에서 매핑 상수/함수만 뽑아 격리된 네임스페이스에 적재."""
    src = open(INSPECTION_PY, encoding='utf-8').read()
    tree = ast.parse(src)
    lines = src.splitlines(keepends=True)

    def seg(node):
        return ''.join(lines[node.lineno - 1:node.end_lineno])

    chunks = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in WANT_FUNCS:
            chunks.append(seg(node))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names = [t.id for t in targets if isinstance(t, ast.Name)]
            if any(n in WANT_CONSTS for n in names):
                chunks.append(seg(node))

    ns = {
        'os': os, 'sqlite3': sqlite3,
        'logger': types.SimpleNamespace(warning=lambda *a: None, info=lambda *a: None,
                                        error=lambda *a: None),
        '_cert_cache_mod': types.SimpleNamespace(_cert_cache_db_path=''),
    }
    exec(''.join(chunks), ns)

    missing = [n for n in WANT_CONSTS + WANT_FUNCS if n not in ns]
    if missing:
        sys.exit(f'inspection.py에서 추출 실패: {missing}')
    return ns


class RecordingMap(dict):
    """_hdqt_from_addr가 어떤 키워드로 팀을 찾았는지 기록."""
    hit = None

    def get(self, key, default=None):
        val = super().get(key, default)
        if val:
            self.hit = key
        return val


def load_learned(path, logic):
    """학습맵 로드. 경로 미지정 시 서버 캐시(tempdir)를 자동 탐색."""
    if not path:
        tmp = tempfile.gettempdir()
        for cand in (os.path.join(tmp, 'learned_addr_map.json'),
                     os.path.join(tmp, 'cert_cache.db')):
            if os.path.exists(cand):
                path = cand
                print(f'학습맵 자동 탐색: {path}')
                break
    if not path:
        return {}, ''
    if not os.path.exists(path):
        sys.exit(f'학습 맵 파일 없음: {path}')
    if path.lower().endswith('.json'):
        with open(path, encoding='utf-8') as f:
            raw = json.load(f)
        learned = logic['_normalize_learned_map'](raw)
        dropped = len(raw) - len(learned)
        if dropped:
            print(f'경고: 학습맵 {len(raw)}개 중 {dropped}개 항목이 유효한 팀이 아니라 제외됨')
        if not learned:
            sys.exit(f'학습맵에 쓸 수 있는 항목이 없습니다: {path}\n'
                     '  구 형식({"access":…,"team":…}) 캐시일 수 있습니다. '
                     '파일을 지우고 cert DB(-l …/cert_cache.db)로 직접 학습시키세요.')
        return learned, path
    learned = logic['_learn_addr_map_from_cert_db'](db_path=path)
    if not learned:
        sys.exit(f'cert DB에서 학습 실패(테이블/컬럼 확인): {path}')
    return learned, path


def load_legal_dong(with_ri):
    """법정동코드 = 시도(2) + 시군구(3) + 읍면동(3) + 리(2).

    시도/시군구 명칭은 토큰 개수로 자르지 않고 상위 코드 행에서 역산한다
    (세종특별자치시처럼 시군구가 없거나 '성남시 분당구'처럼 2토큰인 경우 대응).
    """
    index = {}
    raw = []
    with open(LEGAL_DONG_TSV, encoding='utf-8') as f:
        next(f)
        for line in f:
            p = line.rstrip('\n').split('\t')
            if len(p) < 3 or p[2] != '존재':
                continue
            code, name = p[0].strip(), p[1].strip()
            if len(code) != 10:
                continue
            index[code] = name
            raw.append((code, name))

    rows = []
    for code, name in raw:
        if code[2:] == '00000000':
            continue
        if code[5:] == '00000':
            continue
        level = '읍면동' if code[8:] == '00' else '리'
        if level == '리' and not with_ri:
            continue
        시군구_full = index.get(code[:5] + '00000', '')
        # 세종특별자치시처럼 시도 단독 행이 없는 경우 첫 토큰으로 보정
        시도 = index.get(code[:2] + '00000000', '') or (시군구_full or name).split()[0]
        시군구 = 시군구_full[len(시도):].strip() if 시군구_full.startswith(시도) else 시군구_full
        prefix = 시군구_full or 시도
        하위 = name[len(prefix):].strip() if name.startswith(prefix) else name
        rows.append((code, name, level, 시도, 시군구, 하위))
    return rows


def build(args):
    api_dir = resolve_paths(args.api_dir)
    logic = load_logic()
    learned_raw, learned_src = load_learned(args.learned, logic)
    hdqt_from_addr = logic['_hdqt_from_addr']
    normalize_addr = logic['_normalize_addr']
    SEOUL_SORTED = logic['_SEOUL_GU_SORTED']
    ORG = logic['INSP_ORG_MAP']
    TEAM_TO_HDQT = logic['INSP_TEAM_TO_HDQT']
    ACCESS_TO_SKT = logic['_ACCESS_TO_SKT_HDQT']

    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter

    wb = Workbook()
    head_font = Font(bold=True, color='FFFFFF')
    head_fill = PatternFill('solid', fgColor='2F5597')

    def sheet(title, headers, rows, widths):
        ws = wb.create_sheet(title)
        ws.append(headers)
        for c in ws[1]:
            c.font, c.fill = head_font, head_fill
            c.alignment = Alignment(horizontal='center', vertical='center')
        for r in rows:
            ws.append(r)
        for i, w in enumerate(widths, start=1):
            ws.column_dimensions[get_column_letter(i)].width = w
        ws.freeze_panes = 'A2'
        ws.auto_filter.ref = ws.dimensions
        return ws

    # 1) 조직도
    org_rows = []
    for access, teams in ORG.items():
        for t in teams:
            org_rows.append([ACCESS_TO_SKT.get(access, ''), access, t])
    sheet('조직도', ['SKT본부', 'access담당(본부)', '품질개선팀'], org_rows, [12, 16, 20])

    # 2) 서울 자치구 확정 규칙
    seoul_rows = [[gu, hd, tm] for gu, (hd, tm) in logic['_SEOUL_GU_TO_TEAM'].items()]
    seoul_rows.sort(key=lambda r: (r[1], r[2], r[0]))
    sheet('서울_자치구_규칙', ['자치구', 'access담당(본부)', '품질개선팀'],
          seoul_rows, [12, 16, 20])

    # 3) 법정동 단위 매핑 (메인)
    dong_rows = []
    stat_matched = 0
    for code, name, level, 시도, 시군구, 하위 in load_legal_dong(args.with_ri):
        rec = RecordingMap(learned_raw)
        hdqt, team = hdqt_from_addr(name, learned_map=rec)
        if team:
            stat_matched += 1
            if rec.hit:
                근거 = f'학습맵: {rec.hit}'
            else:
                norm = normalize_addr(name)
                gu = next((k for k, _ in SEOUL_SORTED if k in norm), '')
                근거 = f'서울 자치구 규칙: {gu}' if gu else '확정규칙'
        else:
            근거 = '미매핑'
        dong_rows.append([code, 시도, 시군구, 하위, level, name,
                          ACCESS_TO_SKT.get(hdqt, ''), hdqt or '', team or '', 근거])
    total = len(dong_rows)
    sheet('법정동_팀매핑',
          ['법정동코드', '시도', '시군구', '읍면동', '단위', '전체주소',
           'SKT본부', 'access담당(본부)', '품질개선팀', '판정근거'],
          dong_rows, [13, 14, 18, 14, 8, 42, 10, 14, 20, 26])

    # 4) 시군구 단위 요약 (한 시군구가 여러 팀으로 갈리는지 확인용)
    from collections import defaultdict
    agg = defaultdict(lambda: defaultdict(int))
    for _, 시도, 시군구, _, _, _, _, _, team, _ in dong_rows:
        agg[(시도, 시군구)][team or '(미매핑)'] += 1
    sgg_rows = []
    for (시도, 시군구), counter in sorted(agg.items()):
        items = sorted(counter.items(), key=lambda x: -x[1])
        sgg_rows.append([시도, 시군구, len(items),
                         ', '.join(f'{t}({n})' for t, n in items),
                         items[0][0] if items else ''])
    sheet('시군구_요약', ['시도', '시군구', '팀종류수', '팀별 읍면동수', '대표팀'],
          sgg_rows, [14, 20, 10, 60, 20])

    # 5) 학습된 키워드 → 팀
    lrn_rows = sorted(
        ([kw, t, TEAM_TO_HDQT.get(t, ''), ' ' in kw and '복합키' or '단일키']
         for kw, t in learned_raw.items()),
        key=lambda r: (r[2], r[1], r[0]))
    sheet('학습_키워드_팀', ['주소 키워드', '품질개선팀', 'access담당(본부)', '키유형'],
          lrn_rows, [26, 20, 16, 10])

    # 6) 폐지팀 치환 / 주소 약어 정규화
    sheet('폐지팀_치환', ['구(폐지) 팀명', '현행 팀명'],
          sorted(logic['_DEPRECATED_TEAM_MAP'].items()), [22, 22])
    sheet('주소약어_정규화', ['축약 표기', '정규화 표기'],
          [[a.strip(), f.strip()] for a, f in logic['_ADDR_ABBR_MAP'].items()], [14, 20])

    # 0) 안내 시트
    ws = wb['Sheet']
    ws.title = '안내'
    guide = [
        ['주소 → 품질개선팀 매핑 로직'],
        [''],
        ['생성 스크립트', 'scripts/export_addr_team_map.py'],
        ['로직 원본', f'{api_dir}/routers/inspection.py  _hdqt_from_addr()'],
        ['법정동 원본', LEGAL_DONG_TSV],
        ['학습맵 입력', learned_src or '(없음 — 서울 확정규칙만 반영됨)'],
        [''],
        ['■ 판정 순서'],
        ['1', '주소 정규화 — 앞쪽 괄호 제거, "서울"→"서울특별시" 등 축약 표기 확장 (시트: 주소약어_정규화)'],
        ['2', '서울이면 자치구 확정 규칙표로 즉시 결정 (시트: 서울_자치구_규칙). 가장 긴 키워드 우선'],
        ['3', '서울이 아니면 주소에서 [시/군/구/읍/면/동] 토큰을 뽑아 후보 키를 만든다'],
        ['',  '   복합키: "시 구", "시 군", "시 동", "군 읍", "군 면", "구 동"'],
        ['',  '   단일키: 시/군/구/읍/면 (단독 "동"은 동명이 전국에 중복되어 제외)'],
        ['4', '후보키를 길이 내림차순으로 학습맵에 조회 → 첫 히트의 팀으로 확정 (시트: 학습_키워드_팀)'],
        ['5', '팀이 정해지면 조직도로 본부를 역산 (시트: 조직도)'],
        ['6', '끝까지 못 찾으면 기존 본부값 유지, 팀은 공란'],
        [''],
        ['■ 학습맵이란'],
        ['',  'cert DB(무선국 인증 데이터)의 주소(zpwiadr) + 실제 담당팀(ons_team_nm) 쌍을 집계해'],
        ['',  '키워드별 최빈 팀을 채택한 표. 동일 키워드 3건 미만은 노이즈로 버린다.'],
        ['',  '즉 읍면동 단위 매핑은 하드코딩이 아니라 운영 데이터에서 학습된 결과다.'],
        [''],
        ['■ 커버리지'],
        ['대상 읍면동 수', total],
        ['팀 확정', stat_matched],
        ['미매핑', total - stat_matched],
        ['학습 키워드 수', len(learned_raw)],
    ]
    for row in guide:
        ws.append(row)
    ws['A1'].font = Font(bold=True, size=14)
    for r in ws.iter_rows(min_col=1, max_col=1):
        if r[0].value and str(r[0].value).startswith('■'):
            r[0].font = Font(bold=True, size=11)
    ws.column_dimensions['A'].width = 16
    ws.column_dimensions['B'].width = 100

    out = args.out or os.path.join(ROOT, 'docs', '주소-팀_매핑.xlsx')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    wb.save(out)
    print(f'생성 완료: {out}')
    print(f'  읍면동 {total}건 중 팀 확정 {stat_matched}건 / 미매핑 {total - stat_matched}건')
    print(f'  학습 키워드 {len(learned_raw)}개')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', '--out', help='출력 xlsx 경로')
    ap.add_argument('-l', '--learned',
                    help='학습맵 (.json 캐시 또는 cert_cache.db). 생략 시 임시디렉터리 자동 탐색')
    ap.add_argument('--api-dir', help='inspection.py / legal_dong_code.tsv 가 있는 디렉터리')
    ap.add_argument('--with-ri', action='store_true', help='리(里) 단위까지 포함')
    build(ap.parse_args())
