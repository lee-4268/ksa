"""
설치확인서 HWPX 생성 모듈

HWPX는 한컴오피스의 Open XML 기반 포맷 (ZIP 안에 XML).
OWPML(KS X 6101) 스펙에 따라 XML을 구성하여 HWPX 파일을 생성합니다.
"""
import io
import zipfile
import logging
from xml.sax.saxutils import escape

logger = logging.getLogger(__name__)

MM_TO_HWPU = 283.465

_uid_counter = 0


def _escape(text):
    if not text:
        return ''
    return escape(str(text))


def _uid():
    global _uid_counter
    _uid_counter += 1
    return str(1000000000 + _uid_counter)


def _format_antenna(d):
    ac = int(d.get('antenna_count', 0))
    oac = int(d.get('other_antenna_count', 0))
    return f'{ac}(타{oac})' if oac > 0 else str(ac)


def generate_certificate_hwp(form_data, photo_list=None, blueprint_bytes=None):
    global _uid_counter
    _uid_counter = 0

    output = io.BytesIO()

    image_items = []
    if blueprint_bytes:
        image_items.append(('blueprint', 'blueprint.jpg', 'image/jpeg'))
    if photo_list:
        for i, p in enumerate(photo_list):
            if p:
                image_items.append((f'photo{i}', f'photo{i}.jpg', 'image/jpeg'))

    has_photos = photo_list and len(photo_list) > 0

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zf:
        zi = zipfile.ZipInfo('mimetype')
        zi.compress_type = zipfile.ZIP_STORED
        zf.writestr(zi, 'application/hwp+zip')

        zf.writestr('version.xml', _version_xml())
        zf.writestr('settings.xml', _settings_xml())
        zf.writestr('META-INF/container.xml', _container_xml())
        zf.writestr('META-INF/container.rdf', _container_rdf())
        zf.writestr('META-INF/manifest.xml', _manifest_xml())
        zf.writestr('Preview/PrvText.txt', ' ')
        zf.writestr('Contents/content.hpf', _content_hpf(image_items))
        zf.writestr('Contents/header.xml', _header_xml())
        zf.writestr('Contents/section0.xml',
                     _section_xml(form_data, has_photos, bool(blueprint_bytes)))

        if blueprint_bytes:
            zf.writestr('BinData/blueprint.jpg', blueprint_bytes)
        if photo_list:
            for i, p in enumerate(photo_list):
                if p:
                    zf.writestr(f'BinData/photo{i}.jpg', p)

    output.seek(0)
    return output


def _version_xml():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version"
  tagetApplication="WORDPROCESSOR"
  major="5" minor="1" micro="1" buildNumber="0" os="1"
  xmlVersion="1.5"
  application="Hancom Office Hangul"
  appVersion="13, 0, 0, 1408 WIN32LEWindows_10"/>'''


def _container_xml():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container"
  xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf">
  <ocf:rootfiles>
    <ocf:rootfile full-path="Contents/content.hpf"
      media-type="application/hwpml-package+xml"/>
    <ocf:rootfile full-path="Preview/PrvText.txt"
      media-type="text/plain"/>
    <ocf:rootfile full-path="META-INF/container.rdf"
      media-type="application/rdf+xml"/>
  </ocf:rootfiles>
</ocf:container>'''


def _container_rdf():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="">
    <ns0:hasPart xmlns:ns0="http://www.hancom.co.kr/hwpml/2016/meta/pkg#"
      rdf:resource="Contents/header.xml"/>
  </rdf:Description>
  <rdf:Description rdf:about="Contents/header.xml">
    <rdf:type rdf:resource="http://www.hancom.co.kr/hwpml/2016/meta/pkg#HeaderFile"/>
  </rdf:Description>
  <rdf:Description rdf:about="">
    <ns0:hasPart xmlns:ns0="http://www.hancom.co.kr/hwpml/2016/meta/pkg#"
      rdf:resource="Contents/section0.xml"/>
  </rdf:Description>
  <rdf:Description rdf:about="Contents/section0.xml">
    <rdf:type rdf:resource="http://www.hancom.co.kr/hwpml/2016/meta/pkg#SectionFile"/>
  </rdf:Description>
  <rdf:Description rdf:about="">
    <rdf:type rdf:resource="http://www.hancom.co.kr/hwpml/2016/meta/pkg#Document"/>
  </rdf:Description>
</rdf:RDF>'''


def _manifest_xml():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<odf:manifest xmlns:odf="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"/>'''


def _settings_xml():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<ha:HWPApplicationSetting xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app"
  xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0">
  <ha:CaretPosition listIDRef="0" paraIDRef="0" pos="0"/>
</ha:HWPApplicationSetting>'''


def _content_hpf(image_items=None):
    img_manifest = ''
    if image_items:
        for img_id, href, mtype in image_items:
            img_manifest += f'    <opf:item id="{img_id}" href="BinData/{href}" media-type="{mtype}"/>\n'

    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf/"
  xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"
  xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
  xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
  xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"
  xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf"
  version="" unique-identifier="" id="">
  <opf:metadata>
    <opf:title/>
    <opf:language>ko</opf:language>
  </opf:metadata>
  <opf:manifest>
    <opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>
    <opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/>
    <opf:item id="settings" href="settings.xml" media-type="application/xml"/>
{img_manifest}  </opf:manifest>
  <opf:spine>
    <opf:itemref idref="header" linear="yes"/>
    <opf:itemref idref="section0" linear="yes"/>
  </opf:spine>
</opf:package>'''


def _header_xml():
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"
         xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
         version="1.1" secCnt="1">
  <hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/>
  <hh:refList>
    <hh:fontfaces itemCnt="7">
      <hh:fontface lang="HANGUL"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="LATIN"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="HANJA"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="JAPANESE"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="OTHER"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="SYMBOL"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
      <hh:fontface lang="USER"><hh:font id="0" face="맑은 고딕" type="TTF"/></hh:fontface>
    </hh:fontfaces>
    <hh:borderFills itemCnt="2">
      <hh:borderFill id="1" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">
        <hh:slash type="NONE" Crooked="0" isCounter="0"/>
        <hh:backSlash type="NONE" Crooked="0" isCounter="0"/>
        <hh:leftBorder type="NONE" width="0.12 mm" color="#000000"/>
        <hh:rightBorder type="NONE" width="0.12 mm" color="#000000"/>
        <hh:topBorder type="NONE" width="0.12 mm" color="#000000"/>
        <hh:bottomBorder type="NONE" width="0.12 mm" color="#000000"/>
        <hh:diagonal type="NONE" width="0.12 mm" color="#000000"/>
        <hc:fillBrush><hc:winBrush faceColor="none" hatchColor="#000000" alpha="0"/></hc:fillBrush>
      </hh:borderFill>
      <hh:borderFill id="2" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">
        <hh:slash type="NONE" Crooked="0" isCounter="0"/>
        <hh:backSlash type="NONE" Crooked="0" isCounter="0"/>
        <hh:leftBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:rightBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:topBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:bottomBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/>
        <hc:fillBrush><hc:winBrush faceColor="none" hatchColor="#000000" alpha="0"/></hc:fillBrush>
      </hh:borderFill>
    </hh:borderFills>
    <hh:charProperties itemCnt="7">
      <hh:charPr id="0" height="900" bold="0" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="1" height="1400" bold="1" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="2" height="1200" bold="1" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="3" height="800" bold="0" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#666666">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="4" height="600" bold="0" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="5" height="900" bold="1" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
      <hh:charPr id="6" height="700" bold="1" italic="0" underline="NONE" strikeout="NONE"
        fontRef="0" charColor="#000000">
        <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
      </hh:charPr>
    </hh:charProperties>
    <hh:paraProperties itemCnt="2">
      <hh:paraPr id="0" align="JUSTIFY"><hh:spacing line="160" lineType="PERCENT"/></hh:paraPr>
      <hh:paraPr id="1" align="CENTER"><hh:spacing line="160" lineType="PERCENT"/></hh:paraPr>
    </hh:paraProperties>
    <hh:styles itemCnt="1">
      <hh:style id="0" type="PARA" name="바탕글" engName="Normal"
        paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langId="1042" lockForm="0"/>
    </hh:styles>
  </hh:refList>
</hh:head>'''


def _para(text, char_pr_id=0, para_pr_id=0):
    safe = _escape(text)
    pid = _uid()
    return f'''<hp:p id="{pid}" paraPrIDRef="{para_pr_id}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{char_pr_id}">
    <hp:t>{safe}</hp:t>
  </hp:run>
</hp:p>'''


def _empty_para(para_pr_id=0):
    pid = _uid()
    return f'''<hp:p id="{pid}" paraPrIDRef="{para_pr_id}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="0">
    <hp:t/>
  </hp:run>
</hp:p>'''


def _table_cell(text, col_addr, row_addr, width, height=1200,
                col_span=1, row_span=1, is_header=False, align='LEFT', char_pr_id=None):
    char_id = char_pr_id if char_pr_id is not None else (5 if is_header else 0)
    para_align = 0 if align == 'LEFT' else 1
    bf_id = 2
    safe = _escape(text)
    pid = _uid()
    sid = _uid()

    return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{bf_id}">
        <hp:subList id="{sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{pid}" paraPrIDRef="{para_align}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{char_id}">
              <hp:t>{safe}</hp:t>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="{row_addr}"/>
        <hp:cellSpan colSpan="{col_span}" rowSpan="{row_span}"/>
        <hp:cellSz width="{width}" height="{height}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''


def _section_xml(form_data, has_photos=False, has_blueprint=False):
    d = form_data
    photo_text = "붙임' 참조" if has_photos else '-'

    page_w = 59528
    page_h = 84186
    margin_l = 4252
    margin_r = 4252
    margin_t = 4252
    margin_b = 2835
    content_w = page_w - margin_l - margin_r

    col_h_w = 8504
    col_v_w = (content_w - col_h_w * 2) // 2
    span3_w = col_v_w + col_h_w + col_v_w

    row_h = 2500

    rows_xml = ''

    # 행 0: 시설자명 | 값 | 허가번호 | 값
    rows_xml += f'''    <hp:tr>
{_table_cell('시설자명', 0, 0, col_h_w, row_h, is_header=True)}
{_table_cell(d.get('installer_name', '-'), 1, 0, col_v_w, row_h)}
{_table_cell('허가번호', 2, 0, col_h_w, row_h, is_header=True)}
{_table_cell(d.get('zpwino', '-'), 3, 0, col_v_w, row_h)}
    </hp:tr>'''

    # 행 1: 공동신청 시설자명 | 값 | 공동신청 허가번호 | 값
    def _co_header_cell(label, hint, col_addr):
        _p1 = _uid(); _p2 = _uid(); _s = _uid()
        return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="2">
        <hp:subList id="{_s}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{_p1}" paraPrIDRef="1" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="4">
              <hp:t>{_escape(label)}</hp:t>
            </hp:run>
          </hp:p>
          <hp:p id="{_p2}" paraPrIDRef="1" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="4">
              <hp:t>{_escape(hint)}</hp:t>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="1"/>
        <hp:cellSpan colSpan="1" rowSpan="1"/>
        <hp:cellSz width="{col_h_w}" height="{row_h}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''

    rows_xml += f'''
    <hp:tr>
{_co_header_cell('공동신청 시설자명', '(필요 시 입력)', 0)}
{_table_cell(d.get('co_installer_name', '-'), 1, 1, col_v_w, row_h)}
{_co_header_cell('공동신청 허가번호', '(필요 시 입력)', 2)}
{_table_cell(d.get('co_zpwino', '-'), 3, 1, col_v_w, row_h)}
    </hp:tr>'''

    # 행 2: 안테나설치대 형태 | 값 | 호출명칭 | 값
    rows_xml += f'''
    <hp:tr>
{_table_cell('안테나설치대 형태', 0, 2, col_h_w, row_h, is_header=True, char_pr_id=6)}
{_table_cell(d.get('antenna_frame_type', '-'), 1, 2, col_v_w, row_h)}
{_table_cell('호출명칭', 2, 2, col_h_w, row_h, is_header=True)}
{_table_cell(d.get('zpwina', '-'), 3, 2, col_v_w, row_h)}
    </hp:tr>'''

    # 행 3: 공용화 구분 | 값 | 안테나 수 | 값
    rows_xml += f'''
    <hp:tr>
{_table_cell('공용화 구분', 0, 3, col_h_w, row_h, is_header=True)}
{_table_cell(d.get('sharing_type', '-'), 1, 3, col_v_w, row_h)}
{_table_cell('안테나 수', 2, 3, col_h_w, row_h, is_header=True)}
{_table_cell(_format_antenna(d), 3, 3, col_v_w, row_h, align='CENTER')}
    </hp:tr>'''

    # 행 4: 설치장소 (colspan=3)
    rows_xml += f'''
    <hp:tr>
{_table_cell('설치장소', 0, 4, col_h_w, row_h, is_header=True)}
{_table_cell(d.get('zpwiadr', '-'), 1, 4, span3_w, row_h, col_span=3)}
    </hp:tr>'''

    # 행 5: 특이사항 (colspan=3)
    rows_xml += f'''
    <hp:tr>
{_table_cell('특이사항', 0, 5, col_h_w, row_h, char_pr_id=0)}
{_table_cell(d.get('remark', '-'), 1, 5, span3_w, row_h, col_span=3, align='LEFT')}
    </hp:tr>'''

    # 행 6: 설계도면 (colspan=3)
    bp_text = '붙임 참조' if has_blueprint else '-'
    rows_xml += f'''
    <hp:tr>
{_table_cell('설계도면', 0, 6, col_h_w, row_h, is_header=True)}
{_table_cell(bp_text, 1, 6, span3_w, row_h, col_span=3, align='CENTER')}
    </hp:tr>'''

    # 행 7: 현장 사진 + 필수항목 안내
    _note_pid1 = _uid()
    _note_pid2 = _uid()
    _note_sid = _uid()
    _safe_photo = _escape(photo_text)
    _safe_note = _escape('※ 굵은 글씨 항목은 필수 항목')
    photo_note_cell = f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="2">
        <hp:subList id="{_note_sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{_note_pid1}" paraPrIDRef="0" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="5">
              <hp:t>{_safe_photo}</hp:t>
            </hp:run>
          </hp:p>
          <hp:p id="{_note_pid2}" paraPrIDRef="0" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="3">
              <hp:t>{_safe_note}</hp:t>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="1" rowAddr="7"/>
        <hp:cellSpan colSpan="3" rowSpan="1"/>
        <hp:cellSz width="{span3_w}" height="{row_h}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''

    rows_xml += f'''
    <hp:tr>
{_table_cell('현장 사진', 0, 7, col_h_w, row_h, is_header=True)}
{photo_note_cell}
    </hp:tr>'''

    tbl_id = _uid()
    tbl_p_id = _uid()
    table_xml = f'''<hp:p id="{tbl_p_id}" paraPrIDRef="0" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="0">
    <hp:tbl id="{tbl_id}" zOrder="0" numberingType="TABLE"
      textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0"
      dropcapstyle="None" pageBreak="CELL" repeatHeader="0"
      rowCnt="8" colCnt="4" cellSpacing="0" borderFillIDRef="2"
      noAdjust="0">
      <hp:sz width="{content_w}" widthRelTo="ABSOLUTE"
        height="{row_h * 8}" heightRelTo="ABSOLUTE" protect="0"/>
      <hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1"
        allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA"
        horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT"
        vertOffset="0" horzOffset="0"/>
      <hp:outMargin left="0" right="0" top="0" bottom="0"/>
      <hp:inMargin left="0" right="0" top="0" bottom="0"/>
{rows_xml}
    </hp:tbl>
  </hp:run>
</hp:p>'''

    photo_section = ''
    if has_photos:
        photo_section += _empty_para(0)
        photo_section += _para('[붙임] 현장사진', 2, 1)
        photo_section += _empty_para(0)

    secpr_pid = _uid()

    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<hs:sec xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"
        xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
        xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
        xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head">
  <hp:p id="{secpr_pid}" paraPrIDRef="0" styleIDRef="0"
      pageBreak="0" columnBreak="0" merged="0">
    <hp:run charPrIDRef="0">
      <hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="1134"
        tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT"
        outlineShapeIDRef="1" memoShapeIDRef="0"
        textVerticalWidthHead="0" masterPageCnt="0">
        <hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/>
        <hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/>
        <hp:visibility hideFirstHeader="0" hideFirstFooter="0"
          hideFirstMasterPage="0" border="SHOW_ALL"
          fill="SHOW_ALL" hideFirstPageNum="0"
          hideFirstEmptyLine="0" showLineNumber="0"/>
        <hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/>
        <hp:pagePr landscape="WIDELY" width="{page_w}" height="{page_h}"
          gutterType="LEFT_ONLY">
          <hp:margin header="4252" footer="4252" gutter="0"
            left="{margin_l}" right="{margin_r}"
            top="{margin_t}" bottom="{margin_b}"/>
        </hp:pagePr>
        <hp:footNotePr>
          <hp:autoNumFormat type="DIGIT" suffixChar=")" supscript="0"/>
          <hp:noteLine length="-1" type="SOLID" width="0.12 mm" color="#000000"/>
          <hp:noteSpacing betweenNotes="283" belowLine="567" aboveLine="850"/>
          <hp:numbering type="CONTINUOUS" newNum="1"/>
          <hp:placement place="EACH_COLUMN" beneathText="0"/>
        </hp:footNotePr>
        <hp:endNotePr>
          <hp:autoNumFormat type="DIGIT" suffixChar=")" supscript="0"/>
          <hp:noteLine length="14692308" type="SOLID" width="0.12 mm" color="#000000"/>
          <hp:noteSpacing betweenNotes="0" belowLine="567" aboveLine="850"/>
          <hp:numbering type="CONTINUOUS" newNum="1"/>
          <hp:placement place="END_OF_DOCUMENT" beneathText="0"/>
        </hp:endNotePr>
        <hp:pageBorderFill type="BOTH" borderFillIDRef="1" textBorder="PAPER"
          headerInside="0" footerInside="0" fillArea="PAPER">
          <hp:offset left="1417" right="1417" top="1417" bottom="1417"/>
        </hp:pageBorderFill>
        <hp:pageBorderFill type="EVEN" borderFillIDRef="1" textBorder="PAPER"
          headerInside="0" footerInside="0" fillArea="PAPER">
          <hp:offset left="1417" right="1417" top="1417" bottom="1417"/>
        </hp:pageBorderFill>
        <hp:pageBorderFill type="ODD" borderFillIDRef="1" textBorder="PAPER"
          headerInside="0" footerInside="0" fillArea="PAPER">
          <hp:offset left="1417" right="1417" top="1417" bottom="1417"/>
        </hp:pageBorderFill>
      </hp:secPr>
      <hp:ctrl>
        <hp:colPr id="" type="NEWSPAPER" layout="LEFT"
          colCount="1" sameSz="1" sameGap="0"/>
      </hp:ctrl>
    </hp:run>
    <hp:run charPrIDRef="0">
      <hp:t/>
    </hp:run>
  </hp:p>

  {_para('[별지]', 5, 0)}
  {_empty_para(0)}
  {_para('이동통신무선국', 1, 1)}
  {_para('설치 확인서', 2, 1)}
  {_empty_para(0)}

  {table_xml}

  {photo_section}
</hs:sec>'''
