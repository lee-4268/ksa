"""
설치확인서 PDF 생성 모듈

reportlab을 사용하여 A4 크기의 설치확인서 PDF를 생성합니다.
원본 PDF 서식과 동일한 테이블 구조:
  시설자명 | 값 | 허가번호 | 값
  공동신청 시설자명 | 값 | 공동신청 허가번호 | 값
  안테나설치대 형태 | 값 | 호출명칭 | 값
  공용화 구분 | 값 | 안테나 수 | 값
  설치장소 | 값 (colspan 3)
  특이사항 | 값 (colspan 3)
  설계도면 | 이미지 (colspan 3, 큰 높이)
  현장 사진 | 붙임' 참조 (colspan 3)
  ※ 굵은 글씨 항목은 필수 항목

2페이지: [붙임] 현장사진 (6칸 그리드, 2x3)
"""
import io
import os
import logging

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.platypus import (
    SimpleDocTemplate, Table, TableStyle, Paragraph, Image, PageBreak
)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

logger = logging.getLogger(__name__)

_font_registered = False


def _register_font():
    global _font_registered
    if _font_registered:
        return

    font_paths = [
        '/usr/share/fonts/truetype/nanum/NanumGothic.ttf',
        '/usr/share/fonts/truetype/nanum/NanumGothicBold.ttf',
        'C:/Windows/Fonts/malgun.ttf',
        'C:/Windows/Fonts/malgunbd.ttf',
    ]

    registered = False
    for fp in font_paths:
        if os.path.exists(fp):
            fname = os.path.basename(fp).replace('.ttf', '')
            try:
                pdfmetrics.registerFont(TTFont(fname, fp))
                registered = True
            except Exception as e:
                logger.warning(f"Failed to register font {fp}: {e}")

    if registered:
        _font_registered = True


def _get_font():
    for name in ['NanumGothic', 'malgun']:
        try:
            pdfmetrics.getFont(name)
            return name
        except KeyError:
            continue
    return 'Helvetica'


def _get_bold_font():
    for name in ['NanumGothicBold', 'malgunbd']:
        try:
            pdfmetrics.getFont(name)
            return name
        except KeyError:
            continue
    return _get_font()


def _format_antenna_count(d):
    ac = int(d.get('antenna_count', 0))
    oac = int(d.get('other_antenna_count', 0))
    return f'{ac}(타{oac})' if oac > 0 else str(ac)


def generate_certificate_pdf(form_data, photo_list=None, blueprint_bytes=None):
    """
    Args:
        form_data: dict
        photo_list: list of bytes (최대 6장) 또는 None
        blueprint_bytes: bytes 또는 None
    Returns:
        io.BytesIO with PDF content
    """
    _register_font()
    font = _get_font()
    bold_font = _get_bold_font()

    output = io.BytesIO()
    doc = SimpleDocTemplate(
        output, pagesize=A4,
        leftMargin=15 * mm, rightMargin=15 * mm,
        topMargin=15 * mm, bottomMargin=8 * mm
    )

    page_width = A4[0] - 30 * mm
    page_height = A4[1] - 23 * mm

    styles = getSampleStyleSheet()
    s_badge = ParagraphStyle('Badge', parent=styles['Normal'],
        fontName=bold_font, fontSize=10, leading=14, textColor=colors.black,
        alignment=TA_LEFT, spaceBefore=0, spaceAfter=2*mm)
    s_title = ParagraphStyle('CertTitle', parent=styles['Normal'],
        fontName=bold_font, fontSize=16, leading=22, alignment=TA_CENTER)
    s_cell = ParagraphStyle('Cell', parent=styles['Normal'],
        fontName=font, fontSize=10, leading=14, alignment=TA_CENTER)
    s_cell_left = ParagraphStyle('CellLeft', parent=styles['Normal'],
        fontName=font, fontSize=10, leading=14, alignment=TA_LEFT)
    s_cell_sm = ParagraphStyle('CellSm', parent=styles['Normal'],
        fontName=font, fontSize=8, leading=11, alignment=TA_CENTER)
    s_cell_c = ParagraphStyle('CellC', parent=styles['Normal'],
        fontName=font, fontSize=10, leading=14, alignment=TA_CENTER)
    s_hdr = ParagraphStyle('Hdr', parent=styles['Normal'],
        fontName=bold_font, fontSize=10, leading=14, alignment=TA_CENTER)
    s_hdr_sm = ParagraphStyle('HdrSm', parent=styles['Normal'],
        fontName=font, fontSize=7, leading=10, alignment=TA_CENTER)
    s_hdr_nb = ParagraphStyle('HdrNb', parent=styles['Normal'],
        fontName=font, fontSize=10, leading=14, alignment=TA_CENTER)
    s_hdr_fit = ParagraphStyle('HdrFit', parent=styles['Normal'],
        fontName=bold_font, fontSize=8, leading=11, alignment=TA_CENTER)
    s_photo_title = ParagraphStyle('PhotoTitle', parent=styles['Normal'],
        fontName=bold_font, fontSize=12, leading=16,
        alignment=TA_LEFT, spaceBefore=4*mm, spaceAfter=4*mm)

    def h(text):
        return Paragraph(f'<b>{text}</b>', s_hdr)

    def h_sub(main, sub):
        return Paragraph(f'{main}<br/>{sub}', s_hdr_sm)

    def c(text):
        t = str(text) if text else '-'
        style = s_cell_sm if len(t) > 20 else s_cell
        return Paragraph(t, style)

    def cc(text):
        return Paragraph(str(text) if text else '-', s_cell_c)

    elements = []
    elements.append(Paragraph('[별지] 이동통신무선국 설치 확인서', s_badge))

    col_h = 30 * mm
    col_v = (page_width - col_h * 2) / 2

    d = form_data
    has_photos = photo_list and len(photo_list) > 0
    photo_text = "붙임' 참조" if has_photos else '-'

    badge_h = 10 * mm
    safety = 3 * mm
    title_h = 12 * mm
    fixed_rows_h = title_h + (9 + 11 + 9 + 9 + 9 + 12 + 12) * mm
    bp_row_h = page_height - badge_h - fixed_rows_h - safety
    if not blueprint_bytes:
        bp_row_h = 30 * mm

    bp_content = cc('-')
    if blueprint_bytes:
        try:
            bp_io = io.BytesIO(blueprint_bytes)
            bp_img = Image(bp_io)
            iw, ih = bp_img.drawWidth, bp_img.drawHeight
            max_w = page_width - col_h - 6 * mm
            max_h = bp_row_h - 4 * mm
            ratio = min(max_w / iw, max_h / ih)
            bp_img.drawWidth = iw * ratio
            bp_img.drawHeight = ih * ratio
            bp_img.hAlign = 'CENTER'
            bp_content = bp_img
        except Exception as e:
            logger.warning(f"Failed to load blueprint image: {e}")
            bp_content = cc('이미지 로드 실패')

    # 단일 테이블 (제목 행 포함, SPAN으로 통합)
    table_data = [
        # row 0: 제목 (4칸 통합, 가운데정렬)
        [Paragraph('이동통신무선국 설치 확인서', s_title), '', '', ''],
        # row 1
        [h('시설자명'), c(d.get('installer_name')),
         h('허가번호'), c(d.get('zpwino'))],
        # row 2
        [h_sub('공동신청 시설자명', '(필요 시 입력)'), c(d.get('co_installer_name')),
         h_sub('공동신청 허가번호', '(필요 시 입력)'), c(d.get('co_zpwino'))],
        # row 3: 안테나설치대 형태 (8pt로 줄바꿈 방지)
        [Paragraph('<b>안테나설치대 형태</b>', s_hdr_fit), c(d.get('antenna_frame_type')),
         h('호출명칭'), c(d.get('zpwina'))],
        # row 4
        [h('공용화 구분'), c(d.get('sharing_type')),
         h('안테나 수'), cc(_format_antenna_count(d))],
        # row 5
        [h('설치장소'), c(d.get('zpwiadr')), '', ''],
        # row 6
        [Paragraph('특이사항', s_hdr_nb),
         Paragraph(str(d.get('remark')) if d.get('remark') else '-', s_cell_left), '', ''],
        # row 7
        [h('설계<br/>도면'), bp_content, '', ''],
        # row 8
        [h('현장<br/>사진'), Paragraph(
            f'<b>{photo_text}</b><br/><font size="7">※ <b>굵은 글씨</b> 항목은 필수 항목</font>',
            s_cell_left
        ), '', ''],
    ]

    row_heights = [
        title_h,
        9 * mm, 11 * mm, 9 * mm, 9 * mm,
        9 * mm, 12 * mm, bp_row_h, 12 * mm,
    ]

    table = Table(table_data, colWidths=[col_h, col_v, col_h, col_v],
                  rowHeights=row_heights)
    table.setStyle(TableStyle([
        ('GRID', (0, 0), (-1, -1), 0.4, colors.black),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('TOPPADDING', (0, 0), (-1, -1), 2*mm),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 2*mm),
        ('LEFTPADDING', (0, 0), (-1, -1), 2*mm),
        ('RIGHTPADDING', (0, 0), (-1, -1), 2*mm),
        # 제목 행 4칸 통합
        ('SPAN', (0, 0), (3, 0)),
        # colspan 3 행들
        ('SPAN', (1, 5), (3, 5)),
        ('SPAN', (1, 6), (3, 6)),
        ('SPAN', (1, 7), (3, 7)),
        ('SPAN', (1, 8), (3, 8)),
    ]))
    elements.append(table)

    if has_photos:
        elements.append(PageBreak())
        elements.append(Paragraph('[붙임] 현장사진', s_photo_title))

        photo_count = len(photo_list)
        num_rows = 2 if photo_count <= 4 else 3
        cell_w = page_width / 2
        cell_h = 125 * mm if num_rows == 2 else 85 * mm
        cell_pad = 0.5 * mm

        photo_table_data = []
        for row_idx in range(num_rows):
            row = []
            for col_idx in range(2):
                photo_idx = row_idx * 2 + col_idx
                if photo_idx < photo_count and photo_list[photo_idx]:
                    try:
                        img_io = io.BytesIO(photo_list[photo_idx])
                        img = Image(img_io)
                        iw, ih = img.drawWidth, img.drawHeight
                        max_w = cell_w - cell_pad * 2
                        max_h = cell_h - cell_pad * 2
                        ratio = min(max_w / iw, max_h / ih)
                        img.drawWidth = iw * ratio
                        img.drawHeight = ih * ratio
                        img.hAlign = 'CENTER'
                        row.append(img)
                    except Exception as e:
                        logger.warning(f"Failed to add photo {photo_idx}: {e}")
                        row.append('')
                else:
                    row.append('')
            photo_table_data.append(row)

        photo_table = Table(photo_table_data,
                            colWidths=[cell_w, cell_w],
                            rowHeights=[cell_h] * num_rows)
        photo_table.setStyle(TableStyle([
            ('GRID', (0, 0), (-1, -1), 0.5, colors.black),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('TOPPADDING', (0, 0), (-1, -1), cell_pad),
            ('BOTTOMPADDING', (0, 0), (-1, -1), cell_pad),
            ('LEFTPADDING', (0, 0), (-1, -1), cell_pad),
            ('RIGHTPADDING', (0, 0), (-1, -1), cell_pad),
        ]))
        elements.append(photo_table)

    doc.build(elements)
    output.seek(0)
    return output
