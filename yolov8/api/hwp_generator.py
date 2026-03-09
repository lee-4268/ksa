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


def _detect_image_type(data: bytes):
    """이미지 바이트에서 실제 포맷 감지 → (확장자, MIME) 반환"""
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return 'png', 'image/png'
    if data[:2] == b'\xff\xd8':
        return 'jpg', 'image/jpeg'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return 'webp', 'image/webp'
    if data[:3] == b'GIF':
        return 'gif', 'image/gif'
    if data[:4] == b'\x00\x00\x01\x00':
        return 'bmp', 'image/bmp'
    return 'jpg', 'image/jpeg'


def _format_antenna(d):
    ac = int(d.get('antenna_count', 0))
    oac = int(d.get('other_antenna_count', 0))
    return f'{ac}(타{oac})' if oac > 0 else str(ac)


def generate_certificate_hwp(form_data, photo_list=None, blueprint_bytes=None):
    global _uid_counter
    _uid_counter = 0

    output = io.BytesIO()

    image_items = []
    photo_bin_ids = []  # 사진 바이너리 아이템 ID 목록
    bp_bin_id = None

    if blueprint_bytes:
        bp_ext, bp_mime = _detect_image_type(blueprint_bytes)
        bp_bin_id = 'blueprint'
        image_items.append((bp_bin_id, f'blueprint.{bp_ext}', bp_mime))
    if photo_list:
        for i, p in enumerate(photo_list):
            if p:
                pid = f'photo{i}'
                photo_bin_ids.append(pid)
                p_ext, p_mime = _detect_image_type(p)
                image_items.append((pid, f'photo{i}.{p_ext}', p_mime))

    has_photos = photo_list and len(photo_list) > 0

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zf:
        zi = zipfile.ZipInfo('mimetype')
        zi.compress_type = zipfile.ZIP_STORED
        zf.writestr(zi, 'application/hwp+zip')

        zf.writestr('version.xml', _version_xml())
        zf.writestr('settings.xml', _settings_xml())
        zf.writestr('META-INF/container.xml', _container_xml())
        zf.writestr('META-INF/container.rdf', _container_rdf())
        zf.writestr('META-INF/manifest.xml', _manifest_xml(image_items))
        zf.writestr('Preview/PrvText.txt', ' ')
        zf.writestr('Contents/content.hpf', _content_hpf(image_items))
        zf.writestr('Contents/header.xml', _header_xml())
        zf.writestr('Contents/section0.xml',
                     _section_xml(form_data, has_photos, bool(blueprint_bytes),
                                  photo_bin_ids=photo_bin_ids,
                                  bp_bin_id=bp_bin_id))

        if blueprint_bytes:
            zf.writestr(f'BinData/blueprint.{bp_ext}', blueprint_bytes)
        if photo_list:
            for i, p in enumerate(photo_list):
                if p:
                    p_ext2, _ = _detect_image_type(p)
                    zf.writestr(f'BinData/photo{i}.{p_ext2}', p)

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


def _manifest_xml(image_items=None):
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<odf:manifest xmlns:odf="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">
</odf:manifest>'''


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
            img_manifest += f'    <opf:item id="{img_id}" href="BinData/{href}" media-type="{mtype}" isEmbeded="1"/>\n'

    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf/"
  xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"
  xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
  xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
  xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"
  xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf"
  version="1.0" unique-identifier="" id="">
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
    """한컴 OWPML 표준 header.xml — 템플릿을 그대로 사용하고 커스텀 charPr/paraPr만 추가"""
    import os
    import re
    template_path = os.path.join(os.path.dirname(__file__), 'hwpx_header_template.xml')
    if not os.path.exists(template_path):
        raise FileNotFoundError(f"HWPX 템플릿 파일이 없습니다: {template_path}")

    with open(template_path, 'rb') as f:
        base = f.read().decode('utf-8')

    # borderFill id=3 추가 (SOLID 테두리, 표 셀용)
    extra_bf = (
        '<hh:borderFill id="3" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">'
        '<hh:slash type="NONE" Crooked="0" isCounter="0"/>'
        '<hh:backSlash type="NONE" Crooked="0" isCounter="0"/>'
        '<hh:leftBorder type="SOLID" width="0.12 mm" color="#000000"/>'
        '<hh:rightBorder type="SOLID" width="0.12 mm" color="#000000"/>'
        '<hh:topBorder type="SOLID" width="0.12 mm" color="#000000"/>'
        '<hh:bottomBorder type="SOLID" width="0.12 mm" color="#000000"/>'
        '<hh:diagonal type="NONE" width="0.1 mm" color="#000000"/>'
        '<hc:fillBrush><hc:winBrush faceColor="none" hatchColor="#000000" alpha="0"/></hc:fillBrush>'
        '</hh:borderFill>'
    )
    base = re.sub(
        r'<hh:borderFills\s+itemCnt="\d+"',
        '<hh:borderFills itemCnt="3"', base)
    base = base.replace(
        '</hh:borderFills>',
        extra_bf + '</hh:borderFills>')

    # 템플릿 charPr: id 0~6 (7개) → 우리가 id 7~13 (7개) 추가 → itemCnt=14
    extra_charpr = (
        _charpr(7, 1000)                                      # 본문 10pt
        + _charpr(8, 1600, bold_font_ref='0')                # 제목 16pt bold
        + _charpr(9, 1200, bold_font_ref='0')                # 부제 12pt bold
        + _charpr(10, 700)                                    # 안내문 7pt
        + _charpr(11, 700, bold_font_ref='0')                 # 소형 bold 7pt (공동신청 헤더)
        + _charpr(12, 1000, bold_font_ref='0')                # 본문 bold 10pt (헤더)
        + _charpr(13, 800, bold_font_ref='0')                 # 소형 bold 8pt (안테나설치대)
    )
    base = re.sub(
        r'<hh:charProperties\s+itemCnt="\d+"',
        '<hh:charProperties itemCnt="14"', base)
    base = base.replace(
        '</hh:charProperties>',
        extra_charpr + '</hh:charProperties>')

    # 템플릿 paraPr: id 0~19 (20개) → 우리가 id 20~21 (2개) 추가 → itemCnt=22
    extra_parapr = _extra_para_properties()
    base = re.sub(
        r'<hh:paraProperties\s+itemCnt="\d+"',
        '<hh:paraProperties itemCnt="22"', base)
    base = base.replace(
        '</hh:paraProperties>',
        extra_parapr + '</hh:paraProperties>')

    return base


def _charpr(cid, height, text_color='#000000', font_ref='0', bold_font_ref=None):
    """한컴 표준 형식의 charPr 요소"""
    fr = bold_font_ref if bold_font_ref else font_ref
    return f'''      <hh:charPr id="{cid}" height="{height}" textColor="{text_color}"
        shadeColor="none" useFontSpace="0" useKerning="0" symMark="NONE" borderFillIDRef="2">
        <hh:fontRef hangul="{fr}" latin="{fr}" hanja="{fr}" japanese="{fr}" other="{fr}" symbol="{fr}" user="{fr}"/>
        <hh:ratio hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/>
        <hh:spacing hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
        <hh:relSz hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/>
        <hh:offset hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
        <hh:underline type="NONE" shape="SOLID" color="#000000"/>
        <hh:strikeout shape="NONE" color="#000000"/>
        <hh:outline type="NONE"/>
        <hh:shadow type="NONE" color="#C0C0C0" offsetX="10" offsetY="10"/>
      </hh:charPr>'''


def _extra_para_properties():
    """템플릿에 추가할 paraPr (CENTER 정렬용)"""
    return '''<hh:paraPr id="20" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0" textDir="LTR"><hh:align horizontal="CENTER" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="BREAK_WORD" widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hp:switch><hp:case hp:required-namespace="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar"><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:case><hp:default><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:default></hp:switch><hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr><hh:paraPr id="21" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0" textDir="LTR"><hh:align horizontal="LEFT" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="BREAK_WORD" widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hp:switch><hp:case hp:required-namespace="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar"><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:case><hp:default><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/></hp:default></hp:switch><hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr>'''


def _header_xml_inline():
    """템플릿 파일 없을 때 인라인 header.xml (charPr id 7~13, paraPr id 20~21 사용)"""
    font_face = '''      <hh:fontface lang="{lang}" fontCnt="2">
        <hh:font id="0" face="함초롬돋움" type="TTF" isEmbedded="0">
          <hh:typeInfo familyType="FCAT_GOTHIC" weight="6" proportion="4" contrast="0" strokeVariation="1" armStyle="1" letterform="1" midline="1" xHeight="1"/>
        </hh:font>
        <hh:font id="1" face="함초롬바탕" type="TTF" isEmbedded="0">
          <hh:typeInfo familyType="FCAT_GOTHIC" weight="6" proportion="4" contrast="0" strokeVariation="1" armStyle="1" letterform="1" midline="1" xHeight="1"/>
        </hh:font>
      </hh:fontface>'''
    langs = ['HANGUL', 'LATIN', 'HANJA', 'JAPANESE', 'OTHER', 'SYMBOL', 'USER']
    fontfaces = '\n'.join(font_face.format(lang=l) for l in langs)

    charpr_xml = (
        '<hh:charProperties itemCnt="14">'
        + _charpr(0, 1000)  # 템플릿 기본 charPr 0~6 (최소한 id=0 필요)
        + _charpr(1, 1000, font_ref='0')
        + _charpr(2, 900, font_ref='0')
        + _charpr(3, 900)
        + _charpr(4, 900, font_ref='0')
        + _charpr(5, 1600, text_color='#2E74B5', font_ref='0')
        + _charpr(6, 1100, font_ref='0')
        + _charpr(7, 900)           # _CPR_BODY
        + _charpr(8, 1400, bold_font_ref='0')  # _CPR_TITLE
        + _charpr(9, 1200, bold_font_ref='0')  # _CPR_SUBTITLE
        + _charpr(10, 800, text_color='#666666')  # _CPR_NOTE
        + _charpr(11, 600)          # _CPR_SMALL
        + _charpr(12, 900, bold_font_ref='0')  # _CPR_BODY_BOLD
        + _charpr(13, 700, bold_font_ref='0')  # _CPR_SMALL_BOLD
        + '</hh:charProperties>'
    )

    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"
         xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
         xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"
         version="1.5" secCnt="1">
  <hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/>
  <hh:refList>
    <hh:fontfaces itemCnt="7">
{fontfaces}
    </hh:fontfaces>
    <hh:borderFills itemCnt="3">
      <hh:borderFill id="1" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">
        <hh:slash type="NONE" Crooked="0" isCounter="0"/>
        <hh:backSlash type="NONE" Crooked="0" isCounter="0"/>
        <hh:leftBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:rightBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:topBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:bottomBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/>
      </hh:borderFill>
      <hh:borderFill id="2" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">
        <hh:slash type="NONE" Crooked="0" isCounter="0"/>
        <hh:backSlash type="NONE" Crooked="0" isCounter="0"/>
        <hh:leftBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:rightBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:topBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:bottomBorder type="NONE" width="0.1 mm" color="#000000"/>
        <hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/>
        <hc:fillBrush><hc:winBrush faceColor="none" hatchColor="#999999" alpha="0"/></hc:fillBrush>
      </hh:borderFill>
      <hh:borderFill id="3" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0">
        <hh:slash type="NONE" Crooked="0" isCounter="0"/>
        <hh:backSlash type="NONE" Crooked="0" isCounter="0"/>
        <hh:leftBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:rightBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:topBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:bottomBorder type="SOLID" width="0.12 mm" color="#000000"/>
        <hh:diagonal type="NONE" width="0.1 mm" color="#000000"/>
        <hc:fillBrush><hc:winBrush faceColor="none" hatchColor="#000000" alpha="0"/></hc:fillBrush>
      </hh:borderFill>
    </hh:borderFills>
    {charpr_xml}
    <hh:paraProperties itemCnt="22">
      <hh:paraPr id="0" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0" textDir="LTR"><hh:align horizontal="JUSTIFY" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="BREAK_WORD" widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr>
      {_extra_para_properties()}
    </hh:paraProperties>
    <hh:styles itemCnt="1">
      <hh:style id="0" type="PARA" name="바탕글" engName="Normal" paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/>
    </hh:styles>
  </hh:refList>
  <hh:compatibleDocument targetProgram="HWP201X"><hh:layoutCompatibility/></hh:compatibleDocument>
  <hh:docOption><hh:linkinfo path="" pageInherit="0" footnoteInherit="0"/></hh:docOption>
</hh:head>'''


# charPr ID 매핑 (템플릿 기존 0~6 보존, 커스텀 7~13)
_CPR_BODY = 7       # 본문 10pt (PDF: s_cell 10pt)
_CPR_TITLE = 8      # 제목 16pt bold (PDF: s_title 16pt)
_CPR_SUBTITLE = 9   # 부제 12pt bold (PDF: s_photo_title 12pt)
_CPR_NOTE = 10      # 안내문 7pt (PDF: 7pt 주석)
_CPR_SMALL = 11     # 소형 bold 7pt (공동신청 헤더, PDF: s_hdr_sm)
_CPR_BODY_BOLD = 12 # 본문 bold 10pt (헤더, PDF: s_hdr 10pt bold)
_CPR_SMALL_BOLD = 13 # 소형 bold 8pt (안테나설치대, PDF: s_hdr_fit)

# paraPr ID 매핑 (템플릿 기존 0~19 보존, 커스텀 20~21)
_PPR_JUSTIFY = 0    # JUSTIFY (템플릿 기존)
_PPR_CENTER = 20    # CENTER (추가)
_PPR_LEFT = 21      # LEFT (추가)

# borderFill ID
_BF_NONE = 1        # 테두리 없음
_BF_SOLID = 3       # SOLID 테두리 (표 셀용)


def _para(text, char_pr_id=_CPR_BODY, para_pr_id=_PPR_JUSTIFY):
    safe = _escape(text)
    pid = _uid()
    return f'''<hp:p id="{pid}" paraPrIDRef="{para_pr_id}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{char_pr_id}">
    <hp:t>{safe}</hp:t>
  </hp:run>
</hp:p>'''


def _empty_para(para_pr_id=_PPR_JUSTIFY):
    pid = _uid()
    return f'''<hp:p id="{pid}" paraPrIDRef="{para_pr_id}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{_CPR_BODY}">
    <hp:t/>
  </hp:run>
</hp:p>'''


def _pic_xml(bin_item_id, display_w, display_h, treat_as_char=True):
    """한컴 호환 <hp:pic> 요소 생성 (hc:img 네임스페이스 사용)
    display_w/display_h: 표시 크기 (HWPU). orgSz도 동일하게 설정."""
    pic_id = _uid()
    inst_id = _uid()
    w = display_w
    h = display_h
    cx = w // 2
    cy = h // 2
    tac = "1" if treat_as_char else "0"
    return f'''<hp:pic id="{pic_id}" zOrder="0" numberingType="PICTURE"
      textWrap="SQUARE" textFlow="BOTH_SIDES" lock="0"
      dropcapstyle="None" href="" groupLevel="0"
      instid="{inst_id}" reverse="0">
      <hp:offset x="0" y="0"/>
      <hp:orgSz width="{w}" height="{h}"/>
      <hp:curSz width="{w}" height="{h}"/>
      <hp:flip horizontal="0" vertical="0"/>
      <hp:rotationInfo angle="0" centerX="{cx}" centerY="{cy}" rotateimage="1"/>
      <hp:renderingInfo>
        <hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/>
        <hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/>
        <hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/>
      </hp:renderingInfo>
      <hc:img binaryItemIDRef="{bin_item_id}" bright="0" contrast="0"
        effect="REAL_PIC" alpha="0"/>
      <hp:imgRect>
        <hc:pt0 x="0" y="0"/>
        <hc:pt1 x="{w}" y="0"/>
        <hc:pt2 x="{w}" y="{h}"/>
        <hc:pt3 x="0" y="{h}"/>
      </hp:imgRect>
      <hp:imgClip left="0" right="{w}" top="0" bottom="{h}"/>
      <hp:inMargin left="0" right="0" top="0" bottom="0"/>
      <hp:imgDim dimwidth="{w}" dimheight="{h}"/>
      <hp:sz width="{w}" widthRelTo="ABSOLUTE"
        height="{h}" heightRelTo="ABSOLUTE" protect="0"/>
      <hp:pos treatAsChar="{tac}" affectLSpacing="0" flowWithText="1"
        allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA"
        horzRelTo="PARA" vertAlign="TOP" horzAlign="LEFT"
        vertOffset="0" horzOffset="0"/>
      <hp:outMargin left="0" right="0" top="0" bottom="0"/>
    </hp:pic>'''


def _image_para(bin_item_id, img_width, img_height, para_pr_id=None):
    """인라인 이미지가 포함된 단락 생성"""
    if para_pr_id is None:
        para_pr_id = _PPR_CENTER
    pid = _uid()
    w = int(img_width)
    h = int(img_height)
    return f'''<hp:p id="{pid}" paraPrIDRef="{para_pr_id}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{_CPR_BODY}">
    {_pic_xml(bin_item_id, w, h)}
  </hp:run>
</hp:p>'''


def _table_cell(text, col_addr, row_addr, width, height=1200,
                col_span=1, row_span=1, is_header=False, align='LEFT', char_pr_id=None):
    char_id = char_pr_id if char_pr_id is not None else (_CPR_BODY_BOLD if is_header else _CPR_BODY)
    para_align = _PPR_JUSTIFY if align == 'LEFT' else _PPR_CENTER
    bf_id = _BF_SOLID
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


def _image_table_cell(bin_item_id, col_addr, row_addr, width, height, col_span=1):
    """이미지가 포함된 테이블 셀"""
    sid = _uid()
    pid = _uid()
    # 이미지를 셀 내부에 꽉 채우되 마진 제외
    img_w = width - 284  # 좌우 마진 제외
    img_h = height - 84   # 상하 마진 제외
    return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{_BF_SOLID}">
        <hp:subList id="{sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{pid}" paraPrIDRef="{_PPR_CENTER}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_BODY}">
              {_pic_xml(bin_item_id, img_w, img_h)}
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="{row_addr}"/>
        <hp:cellSpan colSpan="{col_span}" rowSpan="1"/>
        <hp:cellSz width="{width}" height="{height}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''


def _multiline_table_cell(lines, col_addr, row_addr, width, height, char_pr_id=None):
    """여러 줄 텍스트가 포함된 테이블 셀 (헤더 셀용)"""
    cid = char_pr_id if char_pr_id is not None else _CPR_BODY_BOLD
    sid = _uid()
    paras = ''
    for line in lines:
        pid = _uid()
        paras += f'''          <hp:p id="{pid}" paraPrIDRef="{_PPR_CENTER}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{cid}">
              <hp:t>{_escape(line)}</hp:t>
            </hp:run>
          </hp:p>\n'''
    return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{_BF_SOLID}">
        <hp:subList id="{sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
{paras}        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="{row_addr}"/>
        <hp:cellSpan colSpan="1" rowSpan="1"/>
        <hp:cellSz width="{width}" height="{height}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''


def _empty_table_cell(col_addr, row_addr, width, height):
    """빈 테이블 셀"""
    sid = _uid()
    pid = _uid()
    return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{_BF_SOLID}">
        <hp:subList id="{sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{pid}" paraPrIDRef="{_PPR_CENTER}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_BODY}">
              <hp:t/>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="{row_addr}"/>
        <hp:cellSpan colSpan="1" rowSpan="1"/>
        <hp:cellSz width="{width}" height="{height}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''


def _section_xml(form_data, has_photos=False, has_blueprint=False,
                 photo_bin_ids=None, bp_bin_id=None):
    d = form_data
    photo_text = "붙임' 참조" if has_photos else '-'

    # 페이지 설정 (PDF와 동일: A4, 15mm 여백)
    page_w = 59528    # A4 width in HWPU
    page_h = 84186    # A4 height in HWPU
    margin_l = 4252   # 15mm
    margin_r = 4252   # 15mm
    margin_t = 4252   # 15mm
    margin_b = 2268   # 8mm
    content_w = page_w - margin_l - margin_r  # 180mm = 51024 HWPU

    # 컬럼 폭 (PDF: 30mm / 60mm / 30mm / 60mm)
    col_h_w = 8504    # 30mm (헤더 컬럼)
    col_v_w = 17008   # 60mm (값 컬럼)
    span3_w = col_v_w + col_h_w + col_v_w  # 150mm

    # 행 높이 (PDF 기준)
    title_h = 3402    # 12mm (제목 행)
    row_h = 2551      # 9mm (일반 행)
    row_h_co = 3118   # 11mm (공동신청 행)
    row_h_remark = 3402  # 12mm (특이사항 행)
    row_h_photo = 3402   # 12mm (현장사진 행)

    rows_xml = ''

    # 행 0: 제목 (PDF row 0 — colspan=4)
    rows_xml += f'''    <hp:tr>
{_table_cell('이동통신무선국 설치 확인서', 0, 0, content_w, title_h, col_span=4, char_pr_id=_CPR_TITLE, align='CENTER')}
    </hp:tr>'''

    # 행 1: 시설자명 | 값 | 허가번호 | 값
    rows_xml += f'''
    <hp:tr>
{_table_cell('시설자명', 0, 1, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(d.get('installer_name', '-'), 1, 1, col_v_w, row_h, align='CENTER')}
{_table_cell('허가번호', 2, 1, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(d.get('zpwino', '-'), 3, 1, col_v_w, row_h, align='CENTER')}
    </hp:tr>'''

    # 행 2: 공동신청 시설자명 | 값 | 공동신청 허가번호 | 값
    def _co_header_cell(label, hint, col_addr, row_addr):
        _p1 = _uid(); _p2 = _uid(); _s = _uid()
        return f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{_BF_SOLID}">
        <hp:subList id="{_s}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{_p1}" paraPrIDRef="{_PPR_CENTER}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_SMALL}">
              <hp:t>{_escape(label)}</hp:t>
            </hp:run>
          </hp:p>
          <hp:p id="{_p2}" paraPrIDRef="{_PPR_CENTER}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_SMALL}">
              <hp:t>{_escape(hint)}</hp:t>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="{col_addr}" rowAddr="{row_addr}"/>
        <hp:cellSpan colSpan="1" rowSpan="1"/>
        <hp:cellSz width="{col_h_w}" height="{row_h_co}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''

    rows_xml += f'''
    <hp:tr>
{_co_header_cell('공동신청 시설자명', '(필요 시 입력)', 0, 2)}
{_table_cell(d.get('co_installer_name', '-'), 1, 2, col_v_w, row_h_co, align='CENTER')}
{_co_header_cell('공동신청 허가번호', '(필요 시 입력)', 2, 2)}
{_table_cell(d.get('co_zpwino', '-'), 3, 2, col_v_w, row_h_co, align='CENTER')}
    </hp:tr>'''

    # 행 3: 안테나설치대 형태 | 값 | 호출명칭 | 값
    rows_xml += f'''
    <hp:tr>
{_table_cell('안테나설치대 형태', 0, 3, col_h_w, row_h, is_header=True, char_pr_id=_CPR_SMALL_BOLD, align='CENTER')}
{_table_cell(d.get('antenna_frame_type', '-'), 1, 3, col_v_w, row_h, align='CENTER')}
{_table_cell('호출명칭', 2, 3, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(d.get('zpwina', '-'), 3, 3, col_v_w, row_h, align='CENTER')}
    </hp:tr>'''

    # 행 4: 공용화 구분 | 값 | 안테나 수 | 값
    rows_xml += f'''
    <hp:tr>
{_table_cell('공용화 구분', 0, 4, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(d.get('sharing_type', '-'), 1, 4, col_v_w, row_h, align='CENTER')}
{_table_cell('안테나 수', 2, 4, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(_format_antenna(d), 3, 4, col_v_w, row_h, align='CENTER')}
    </hp:tr>'''

    # 행 5: 설치장소 (colspan=3)
    rows_xml += f'''
    <hp:tr>
{_table_cell('설치장소', 0, 5, col_h_w, row_h, is_header=True, align='CENTER')}
{_table_cell(d.get('zpwiadr', '-'), 1, 5, span3_w, row_h, col_span=3, align='CENTER')}
    </hp:tr>'''

    # 행 6: 특이사항 (colspan=3)
    rows_xml += f'''
    <hp:tr>
{_table_cell('특이사항', 0, 6, col_h_w, row_h_remark, char_pr_id=_CPR_BODY, align='CENTER')}
{_table_cell(d.get('remark', '-'), 1, 6, span3_w, row_h_remark, col_span=3, align='LEFT')}
    </hp:tr>'''

    # 행 7: 설계도면 — 도면이 있으면 이미지 삽입, 없으면 텍스트
    bp_row_h = 8504 if not has_blueprint else 40400  # 30mm 또는 ~142.5mm (표 전체 225.92mm 이내)
    if has_blueprint and bp_bin_id:
        # 도면 이미지를 셀 안에 직접 삽입
        rows_xml += f'''
    <hp:tr>
{_multiline_table_cell(['설계', '도면'], 0, 7, col_h_w, bp_row_h)}
{_image_table_cell(bp_bin_id, 1, 7, span3_w, bp_row_h, col_span=3)}
    </hp:tr>'''
    else:
        rows_xml += f'''
    <hp:tr>
{_multiline_table_cell(['설계', '도면'], 0, 7, col_h_w, bp_row_h)}
{_table_cell('-', 1, 7, span3_w, bp_row_h, col_span=3, align='CENTER')}
    </hp:tr>'''

    # 행 8: 현장 사진 + 필수항목 안내
    _note_pid1 = _uid()
    _note_pid2 = _uid()
    _note_sid = _uid()
    _safe_photo = _escape(photo_text)
    _safe_note = _escape('※ 굵은 글씨 항목은 필수 항목')
    photo_note_cell = f'''      <hp:tc name="" header="0" hasMargin="0" protect="0"
          editable="0" dirty="0" borderFillIDRef="{_BF_SOLID}">
        <hp:subList id="{_note_sid}" textDirection="HORIZONTAL"
          lineWrap="BREAK" vertAlign="CENTER"
          linkListIDRef="0" linkListNextIDRef="0"
          textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">
          <hp:p id="{_note_pid1}" paraPrIDRef="{_PPR_JUSTIFY}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_BODY_BOLD}">
              <hp:t>{_safe_photo}</hp:t>
            </hp:run>
          </hp:p>
          <hp:p id="{_note_pid2}" paraPrIDRef="{_PPR_JUSTIFY}" styleIDRef="0"
            pageBreak="0" columnBreak="0" merged="0">
            <hp:run charPrIDRef="{_CPR_NOTE}">
              <hp:t>{_safe_note}</hp:t>
            </hp:run>
          </hp:p>
        </hp:subList>
        <hp:cellAddr colAddr="1" rowAddr="8"/>
        <hp:cellSpan colSpan="3" rowSpan="1"/>
        <hp:cellSz width="{span3_w}" height="{row_h_photo}"/>
        <hp:cellMargin left="142" right="142" top="42" bottom="42"/>
      </hp:tc>'''

    rows_xml += f'''
    <hp:tr>
{_multiline_table_cell(['현장', '사진'], 0, 8, col_h_w, row_h_photo)}
{photo_note_cell}
    </hp:tr>'''

    total_rows = 9
    total_h = title_h + row_h * 3 + row_h_co + row_h_remark + bp_row_h + row_h_photo + row_h

    tbl_id = _uid()
    tbl_p_id = _uid()
    table_xml = f'''<hp:p id="{tbl_p_id}" paraPrIDRef="{_PPR_JUSTIFY}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{_CPR_BODY}">
    <hp:tbl id="{tbl_id}" zOrder="0" numberingType="TABLE"
      textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0"
      dropcapstyle="None" pageBreak="CELL" repeatHeader="0"
      rowCnt="{total_rows}" colCnt="4" cellSpacing="0" borderFillIDRef="{_BF_SOLID}"
      noAdjust="0">
      <hp:sz width="{content_w}" widthRelTo="ABSOLUTE"
        height="{total_h}" heightRelTo="ABSOLUTE" protect="0"/>
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

    # 현장사진 이미지 (4행 2열 테이블) - 별도 페이지
    photo_section = ''
    if has_photos and photo_bin_ids:
        photo_section += _empty_para()
        photo_section += _para('[붙임] 현장사진', _CPR_SUBTITLE, _PPR_CENTER)
        photo_section += _empty_para()

        # 4행 2열 사진 테이블 (PDF: 90mm x 62mm per cell)
        photo_col_w = content_w // 2  # 90mm
        photo_row_h = 17574           # 62mm
        photo_rows_xml = ''
        for row_idx in range(4):
            photo_rows_xml += '    <hp:tr>\n'
            for col_idx in range(2):
                photo_idx = row_idx * 2 + col_idx
                if photo_idx < len(photo_bin_ids):
                    photo_rows_xml += _image_table_cell(
                        photo_bin_ids[photo_idx], col_idx, row_idx,
                        photo_col_w, photo_row_h)
                else:
                    photo_rows_xml += _empty_table_cell(
                        col_idx, row_idx, photo_col_w, photo_row_h)
                photo_rows_xml += '\n'
            photo_rows_xml += '    </hp:tr>\n'

        photo_tbl_id = _uid()
        photo_tbl_p_id = _uid()
        photo_section += f'''<hp:p id="{photo_tbl_p_id}" paraPrIDRef="{_PPR_JUSTIFY}" styleIDRef="0"
    pageBreak="0" columnBreak="0" merged="0">
  <hp:run charPrIDRef="{_CPR_BODY}">
    <hp:tbl id="{photo_tbl_id}" zOrder="0" numberingType="TABLE"
      textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0"
      dropcapstyle="None" pageBreak="CELL" repeatHeader="0"
      rowCnt="4" colCnt="2" cellSpacing="0" borderFillIDRef="{_BF_SOLID}"
      noAdjust="0">
      <hp:sz width="{content_w}" widthRelTo="ABSOLUTE"
        height="{photo_row_h * 4}" heightRelTo="ABSOLUTE" protect="0"/>
      <hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1"
        allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA"
        horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT"
        vertOffset="0" horzOffset="0"/>
      <hp:outMargin left="0" right="0" top="0" bottom="0"/>
      <hp:inMargin left="0" right="0" top="0" bottom="0"/>
{photo_rows_xml}    </hp:tbl>
  </hp:run>
</hp:p>'''

    secpr_pid = _uid()

    return f'''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<hs:sec xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"
        xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
        xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"
        xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head">
  <hp:p id="{secpr_pid}" paraPrIDRef="{_PPR_JUSTIFY}" styleIDRef="0"
      pageBreak="0" columnBreak="0" merged="0">
    <hp:run charPrIDRef="{_CPR_BODY}">
      <hp:secPr id="{_uid()}" textDirection="HORIZONTAL" spaceColumns="1134"
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
        <hp:colPr id="{_uid()}" type="NEWSPAPER" layout="LEFT"
          colCount="1" sameSz="1" sameGap="0"/>
      </hp:ctrl>
    </hp:run>
    <hp:run charPrIDRef="{_CPR_BODY}">
      <hp:t>[별지] 이동통신무선국 설치 확인서</hp:t>
    </hp:run>
  </hp:p>

  {table_xml}

  {photo_section}
</hs:sec>'''
