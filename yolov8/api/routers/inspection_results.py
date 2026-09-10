"""
inspection_results - 검사실적 RAW DATA 관리 엔드포인트

담당 도메인: 검사실적 xlsx 업로드, 대시보드, 트렌드, 분석, 내보내기
주요 의존성: core.auth, core.config, core.cert_cache
엔드포인트:
    POST /inspection-results/upload
    GET  /inspection-results/dashboard
    GET  /inspection-results/dashboard/monthly
    GET  /inspection-results/trend
    GET  /inspection-results/raw
    GET  /inspection-results/analysis
    GET  /inspection-results/weekly-trend
    GET  /inspection-results/weekly-trend-by-region
    GET  /inspection-results/summary-report
    GET  /inspection-results/weeks
    POST /inspection-results/export-xlsx
"""

import asyncio
import io
import itertools
import logging
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Union
from urllib.parse import quote as _url_quote

from fastapi import APIRouter, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from core.auth import _verify_auth, _get_user_role_sync
from core.config import _INSP_DB
from core.cert_cache import _cert_cache_db_path
from core.inspection_db import _init_inspection_db

logger = logging.getLogger(__name__)

try:
    import openpyxl
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

router = APIRouter(tags=["inspection_results"])

# ── 장비타입 간소화 매핑 ─────────────────────────────────────────────
_EQP_TYPE_SIMPLIFY = {
    "0x2a": "MIBOS",
    "800-SHRFW20-S1R": "SRF-W",
    "AAU10-3.5G-32T(EL)": "RRU",
    "AAU10-3.5G-32T(SS)": "AAU",
    "AAU20-3.5G-32T(EL)": "AAU",
    "AAU20-3.5G-32T(SS)": "AAU",
    "AAU20-3.5G-64T(EL)": "RRU",
    "AAU20-3.5G-64T(SS)": "AAU",
    "AAU21-3.5G-32T(SS)": "AAU",
    "ARRU_L(SS)": "RRU",
    "ARRU_WL(SS)": "RRU",
    "Airscale 5G MAA_AVQL": "AAU",
    "Airscale 5G MAA_Band n78_AEQY": "AAU",
    "Airscale 5G MAA_Band n78_AQQL": "AAU",
    "CRU_L10(NSN)": "RRU",
    "CRU_L10(SS)": "RRU",
    "CSW-4903-RRFU": "OMW-DUO",
    "DBRRU(SS)-WL": "RRU",
    "DR-NODEB(외)": "W기지국",
    "DUO-IBSF": "DUO-IBS",
    "E3-NODEB(내)": "W기지국",
    "E3-NODEB(외)": "W기지국",
    "ERRHS": "ERRH",
    "ERRUP": "ERRU",
    "FX-NODEB": "W기지국",
    "Flexi Multiradio BTS": "RRU",
    "Flexi Multiradio RRH_Band 1_3": "RRU",
    "Flexi Multiradio RRH_Band 3": "RRU",
    "Flexi Multiradio RRH_Band 7": "RRU",
    "Flexi Multiradio RRH_Band n78": "AAU",
    "GST-SF-W15": "SF중계기",
    "ICS-W1": "ICS",
    "ICS-W20": "ICS",
    "ICS-W5": "ICS",
    "ICS-WN20": "ICS",
    "IMT1050026": "SF중계기",
    "IMT1050028": "SF중계기",
    "KCC-CRI-LE1-RRUS11B5": "RRU",
    "KCC-CRI-LE1-RRUS11B5-40W": "RRU",
    "KCC-CRM-CSW-1SFF-B707": "RHU",
    "LR-DUO2": "LR-DUO",
    "LR-DUO5": "LR-DUO",
    "LR-DUOF6": "LR-DUO",
    "LR-DUON5": "LR-DUO",
    "MIBOS-T-L60 RO-세로형": "MIBOS",
    "MIBOS-WL-L10": "WLME",
    "MPR-DUOF0530_IBS": "MPR-DUO",
    "MPR-DUOF6_IBS": "MPR-DUO",
    "MPR-DUON0520_IBS": "MPR",
    "MPR-RHU-W5,MPR-RHU-WN5": "RHU",
    "MPR-RHU-WN20": "RHU",
    "MPRDN-RHUW": "RHU",
    "MPRDUO-RHU-R,MPRDN-RHU": "RHU",
    "MRRU_L10(ELG)": "RRU",
    "MSIP-CRI-LE1-RRU22F1B3D": "RRU",
    "MSIP-CRI-LE1-RRUS12B1": "RRH",
    "MSIP-CRI-LE1-RRUS12B3-20M": "RRU",
    "MSIP-CRI-LE1-RRUS13B1": "RRU",
    "MSIP-CRI-LE1-Radio2212B7": "RRU",
    "MSIP-CRI-LE1-Radio2217B7": "RRU",
    "MSIP-CRM-800-SHTLHD-S1": "MIBOS",
    "MSIP-CRM-CSW-1SFA-T802TL60": "MIBOS",
    "MSIP-CRM-CSW-RROIROT80W6RLD": "IRO",
    "MSIP-CRM-GST-MIBOS-T-L60R-S": "MIBOS",
    "MSIP-CRM-GST-MIBOS-T-L60ROR": "MIBOS",
    "MSIP-CRM-STC-MIBOS-Ad-L60LW": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L0LW": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L26LO": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L60LW": "MIBOS",
    "MSIP-CRM-STC-RMIBQROTL": "MIBOS",
    "MSIP-CRM-STC-RMIBTROLD60": "MIBOS",
    "MSIP-CRM-STC-RMiBLROLO25": "MIBOS",
    "MSIP-CRM-STC-RMiBQROTL": "MIBOS",
    "MSIP-CRM-STC-RMiBTROLD60": "MIBOS",
    "MSIP-CRM-STC-RMiBWMCL05": "MIBOS",
    "MSIP-CRM-STC-RROIROQ8126RLD": "IRO",
    "MSIP-CRM-STC-RROIROT8120LD": "IRO",
    "MSIP-CRM-TSK-MIBOS-TF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MIBOS-TF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-DF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-QF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TSF-L60": "MIBOS",
    "MiBOS-Ad-L26": "MIBOS",
    "MiBOS-Ad-L60": "MIBOS",
    "MiBOS-T-L60-AH": "MIBOS",
    "MiBOS-T-L60-BH": "MIBOS",
    "MiBOS-TS-L60-H": "MIBOS",
    "MiBOS-WL-L10": "WLME",
    "NLG-iBTSOutdoorS": "W기지국",
    "NLG-iBTSOutdoorSH": "W기지국",
    "OR-DUO2": "OR-DUO",
    "OR-DUO5": "OR-DUO",
    "OR-DUON5": "OR-DUO",
    "OR-DUOR2": "OR-DUO",
    "OR-DUOR5": "OR-DUO",
    "OR-DUORC6": "OR-DUO",
    "OTTA-W20": "TTA",
    "PRU10-3.5G-4T": "PRU",
    "PRU10-3.5G-4T(EL)": "PRU",
    "PRU10-3.5G-8T(SS)": "PRU",
    "R-C-CSW-ROIRODS8100LO": "IRO",
    "R-C-Hfr-PRU10-3-5G-4T": "PRU",
    "R-C-LE1-AIR3227B43": "AAU",
    "R-C-LE1-AIR3239B78C": "AAU",
    "R-C-LE1-AIR6419B78Y": "AAU",
    "R-C-LE1-AIR6488B43": "AAU",
    "R-C-LE1-Radi2242B1B3": "RRU",
    "R-C-LE1-Radio4422B78C": "PRU",
    "R-C-STC-ROIROD0120RLW": "IRO",
    "R-C-STC-ROIRODS0120LW": "IRO",
    "R-C-STC-ROIROTS8120LD": "IRO",
    "R-C-STC-ROgIRODS0120": "GIRO",
    "R-C-STC-ROgIRODS8100": "GIRO",
    "R-C-STC-ROgIROTS8120": "GIRO",
    "R-IMT1-05-0028": "SF중계기",
    "RAU-DUO5": "RAU",
    "RAU-DUON5": "RAU",
    "RHU-DUO0520": "RHU",
    "RHU-DUO0520-MHU": "RHU",
    "RHU-DUO0520-OMHU": "RHU",
    "RHU-DUO0530-OMHU": "RHU",
    "RHU-DUO20-MHU": "RHU",
    "RHU-DUO20-OMHU": "RHU",
    "RHU-DUO5": "RHU",
    "RHU-DUO5-MHU": "RHU",
    "RHU-DUOC0520": "RHU",
    "RHU-DUOC0520-OMHU": "RHU",
    "RHU-DUOC0530": "RHU",
    "RHU-DUOF30-MHU": "RHU",
    "RHU-DUOF30-OMHU": "RHU",
    "RHU-DUOF6": "RHU",
    "RHU-DUOF6-MHU": "RHU",
    "RHU-DUON20": "RHU",
    "RHU-DUON20-MHU": "RHU",
    "RHU-DUON20-OMHU": "RHU",
    "RHU-DUON30": "PRU",
    "RHU-DUON30-OMHU": "RHU",
    "RHU-DUON5": "RHU",
    "RHU-DUON5-MHU": "RHU",
    "RHU-DUON5-OMHU": "RHU",
    "RHU-DUON6": "RHU",
    "RHU-DUON6-OMHU": "RHU",
    "RHU-DUONC20-MHU": "RHU",
    "RHU-DUONC5-OMHU": "RHU",
    "RHU-WF30-MHU": "RHU",
    "RHU-WF30-OMHU": "RHU",
    "RHU-WF6-OMHU": "RHU",
    "RHU-WN20": "RHU",
    "RHU-WN20-OMHU": "RHU",
    "RHU-WN30": "RHU",
    "RHU-WN5-MHU": "RHU",
    "RHU-WN5-OMHU": "RHU",
    "RMiBLRO": "MIBOS",
    "RMiBTRO": "MIBOS",
    "RMiBTSRO": "MIBOS",
    "RMiBWM": "MIBOS",
    "RO-DUO-AA2020": "RO-DUO",
    "RO-DUO-AA2020-CMHU": "RO-DUO",
    "RO-DUO-AA2030": "RO-DUO",
    "RO-DUO-AA2030-CMHU": "RO-DUO",
    "RO-DUO-DD4060": "RO-DUO",
    "RO-DUO-DD4060-CMHU": "RO-DUO",
    "RO-DUON5": "RO-DUO",
    "RO-DUON5-MHU": "RO-DUO",
    "RO-DUON5-MOU": "RO-DUO",
    "RO-DUONC5-MOU": "RO-DUO",
    "RO-GIRO-DS(0120)": "GIRO",
    "RO-GIRO-T(8120)": "GIRO",
    "RO-GIRO-TS(8120)": "GIRO",
    "RO-IRO-D(0120)": "IRO",
    "RO-IRO-D(8020)-SMHS(1C)": "IRO",
    "RO-IRO-D(8100)": "IRO",
    "RO-IRO-D(8100)-IMHS": "IRO",
    "RO-IRO-D(8100)-QMHS": "IRO",
    "RO-IRO-D(8100)-SMHS(1C)": "IRO",
    "RO-IRO-DS(0120)": "IRO",
    "RO-IRO-DS(8020)": "IRO",
    "RO-IRO-DS(8020)-SMHS(1C)": "IRO",
    "RO-IRO-DS(80W0)": "IRO",
    "RO-IRO-DS(8100)-SMHS(1C)": "IRO",
    "RO-IRO-Q(8126)": "IRO",
    "RO-IRO-Q(8126)-IMHS": "IRO",
    "RO-IRO-Q(8126)-SMHS(1C)": "IRO",
    "RO-IRO-Q(81W6)": "IRO",
    "RO-IRO-Q(81W6)-IMHS": "IRO",
    "RO-IRO-QS(8126)-SMHS(2C)": "IRO",
    "RO-IRO-QS(81W6)": "IRO",
    "RO-IRO-SS(0020)": "IRO",
    "RO-IRO-T(01W6)": "IRO",
    "RO-IRO-T(80W6)": "IRO",
    "RO-IRO-T(80W6)-IMHS": "IRO",
    "RO-IRO-T(8120)": "IRO",
    "RO-IRO-T(8120)-IMHS": "IRO",
    "RO-IRO-T(8120)-SMHS(1C)": "IRO",
    "RO-IRO-T(81W0)": "IRO",
    "RO-IRO-T(81W0)-IMHS": "IRO",
    "RO-IRO-T(81W0)-SMHS(1C)": "IRO",
    "RO-IRO-TS(8120)": "IRO",
    "RO-IRO-TS(8120)-SMHS(1C)": "IRO",
    "RO-IRO-TS(81W0)": "IRO",
    "RO-IRO-TS(81W0)-SMHS(1C)": "IRO",
    "RO-IRO_SLIM-Q(8126)": "IRO",
    "RO-MBS-T-L60-SMHS-3C": "MIBOS",
    "RO-MBS-TS-L60-SMHS-3C": "MIBOS",
    "RO-MIBOS-AD-L0": "MIBOS",
    "RO-MIBOS-AD-L0(2.6)": "MIBOS",
    "RO-MIBOS-AD-L60": "MIBOS",
    "RO-MIBOS-AD-L60-AMHS": "MIBOS",
    "RO-MIBOS-CL-L60": "MIBOS",
    "RO-MIBOS-CL-L60-QMHS": "MIBOS",
    "RO-MIBOS-D-L60": "MIBOS",
    "RO-MIBOS-D-L60-QMHS": "MIBOS",
    "RO-MIBOS-Q-L60": "MIBOS",
    "RO-MIBOS-Q-L60-QMHS": "MIBOS",
    "RO-MIBOS-T-L0-QMHS": "MIBOS",
    "RO-MIBOS-T-L60": "MIBOS",
    "RO-MIBOS-T-L60-QMHS": "MIBOS",
    "RO-MIBOS-TS-L60": "MIBOS",
    "RO-MIBOS-TS-L60-QMHS": "MIBOS",
    "RO-MIBOS-WL(ME)-L05": "MIBOS",
    "RO-MIBOS-WL(ME)-L05-QMHS": "WLME",
    "RO-MIBOS-WL-L10": "MIBOS",
    "RO-MIBOS-WL-L10-QMHS": "MIBOS",
    "RO-PRU-3.5G-4T": "PRU",
    "RO-PRU-3.5G-4T-LSH310(EL)": "PRU",
    "RO-PRU-3.5G-4T-LSH310(SS)": "PRU",
    "RO-W-D60": "WRO",
    "RO-W-D60-CMHU": "DDR",
    "ROIRODS8020": "IRO",
    "ROIROTS8120": "IRO",
    "RRH_L(ELG)-WL": "RRH",
    "RRH_L(LGE)": "RRU",
    "RRH_L(NSN)": "RRU",
    "RROIROQ8126R": "IRO",
    "RROIROQ81W6R": "IRO",
    "RROIROT8120": "IRO",
    "RRU(0120)_AHEGA(NSN)": "RRU",
    "RRU(0120)_AHEGA(NSN)-WL": "RRU",
    "RRU(0120)_R2242(ELG)": "RRU",
    "RRU(0120)_R2242(ELG)-WL": "RRU",
    "RRUS12(ELG)-WL": "RRU",
    "RRUS13(ELG)": "RRU",
    "RRUS13(ELG)-WL": "RRU",
    "RRU_1.8G_FHEA(NSN)": "RRU",
    "RRU_2.6G_ARRU(SS)": "RRU",
    "RRU_2.6G_FRHG(NSN)": "RRU",
    "RRU_2.6G_R2212(ELG)": "RRU",
    "RRU_2.6G_R2217(ELG)": "RRU",
    "RRU_2.6G_R4415(ELG)": "RRU",
    "RRU_800M_R2212(ELG)": "RRU",
    "RRU_FHEB(NSN)": "RRU",
    "RRU_FRGT(NSN)-WL": "RRU",
    "RRU_L(SS)": "RRU",
    "RU(NSN)": "RRU",
    "RU_FXEB(NSN)": "RRU",
    "SF-DUO": "SF중계기",
    "SF-DUO20": "SF중계기",
    "SF-DUOR": "SF중계기",
    "SF-TF433": "SF중계기",
    "SF-TMF463": "SF중계기",
    "SF-W15": "SF중계기",
    "SF-W20": "SF중계기",
    "SF-WIMF33": "SF중계기",
    "SF-WN20": "SF중계기",
    "SF-WR15": "SF중계기",
    "SF-WR20": "SF중계기",
    "SFDUO-R(C60W20)": "SF중계기",
    "SHTLHD-S1": "TRIO",
    "SPSFFRTTS0": "SF중계기",
    "SRF-W15": "SF중계기",
    "SRF-W20": "SF중계기",
    "SRRU(SS)": "RRU",
    "SRRU_D(SS)": "RRU",
    "SS E3NODEB": "W기지국",
    "SS-E3NODEB": "W기지국",
    "STC-SFW-R15": "SF중계기",
    "TRIO-LH": "TRIO",
    "WAFMCA": "WAFMC",
    "WAFMCB": "WAFMC",
    "WINS PLUSF": "WINS",
    "etr-SF-W15-REMOTE": "SF중계기",
}

_EQP_KEYWORD_RULES = [
    ("GIRO", "GIRO"),
    ("IRO", "IRO"),
    ("MIBOS", "MIBOS"), ("MiBOS", "MIBOS"), ("MBS", "MIBOS"),
    ("AAU", "AAU"),
    ("PRU", "PRU"),
    ("ARRU", "RRU"), ("MRRU", "RRU"), ("SRRU", "RRU"), ("DBRRU", "RRU"),
    ("ERRU", "ERRU"), ("RRU", "RRU"), ("RRH", "RRH"),
    ("RHU", "RHU"),
    ("TRIO", "TRIO"),
    ("WAFMC", "WAFMC"), ("WINS", "WINS"), ("WLME", "WLME"),
    ("ICS", "ICS"),
    ("LR-DUO", "LR-DUO"), ("OR-DUO", "OR-DUO"), ("RO-DUO", "RO-DUO"),
    ("SF-DUO", "SF중계기"), ("SF-W", "SF중계기"), ("SF-", "SF중계기"), ("SRF-W", "SF중계기"),
    ("DUO", "DUO"),
    ("NODEB", "W기지국"), ("iBTS", "W기지국"),
]

_IRR_HEADER_MAP = {
    "주차": "주차별",
    "주차별": "주차별",
    "주별": "주차별",
    "주차구별": "주차별",
    "월": "월",
    "구분": None,
    "연도": None,
    "SKT본부": "skt본부",
    "ONS 본부": "_ons본부",
    "ONS본부": "_ons본부",
    "허가번호": "허가번호",
    "통합시설코드": "통합시설코드",
    "통합시설코": "통합시설코드",
    "호출명칭": "호출명칭",
    "주소": "주소",
    "기지국/중계기 여부": "기지국구분",
    "시스템": "시스템",
    "정기검사 년도": "검사년도",
    "정기검사년도": "검사년도",
    "검사년도": "검사년도",
    "정기/시기조정": "검사종류",
    "정기/이월구분": "_이월구분_auto",
    "검사일자": "검사일자",
    "1. ONS(팀)": "ons팀",
    "수검자": "수검자",
    "입회자": "수검자",
    "전파진흥원": "전파진흥원",
    "진흥원본부": "전파진흥원",
    "검사관": "검사관",
    "진행여부": "진행여부",
    "합격,불합격여부": "합불여부",
    "성능/서류": "성능서류",
    # V12 결과장 신설 2열.
    #   '부적합'(V): 부적합 판정 전용 열 — 부적합 관리 대상은 이 열이 '부적합'인 건만.
    #   '부적합내용'(Y): 부적합 사유 분류값 — 기존엔 불합격상세사유(X)를 끌어다 썼다.
    #   X(불합격상세사유)는 불합격 상세 서술이라 성격이 달라 그대로 별도 적재한다.
    "부적합": "부적합",
    "부적합내용": "부적합내용",
    "불합격내용": "불합격내용",
    "불합격상세사유": "불합격상세",
    "공용화 정비대상 유/무": "공용화대상",
    "기타사항": "기타사항",
    "기타사항(폐국 및 대개체국소)": "기타사항",
    "간략불합격내역": "간략불합격",
    "간략 불합격 내역": "간략불합격",
    "5G Path 확인 방법": "five_g_path",
    "허가번호 장비 Type": "장비타입",
    # 결과장 AM열. 헤더가 '장비Type\n간소화'(2줄)라 첫 줄만 취하면 AJ열 단독
    # '장비Type'과 구별되지 않는다. 개행 제거 형태(headers_full)로 매칭한다.
    # 이 열을 읽지 않으면 시트에 이미 적힌 간소화 값을 버리고 매번 AD열에서
    # 파생시키게 되는데, AD열은 비어 있는 행이 많아(V12 기준 41%) 추론이 실패한다.
    "장비타입간소화": "장비타입간소화",
    "장비Type간소화": "장비타입간소화",
}

_ONS_REGION_MAP = {
    "경북": "경북", "경남": "경남",
    "강원": "강원", "강원Access": "강원",
    "강남": "강남", "강남본부": "강남",
    "강북": "강북", "강북본부": "강북",
    "경기": "경기",
    "인천": "인천", "인천본부": "인천",
    "충청": "충청", "충남": "충청", "충북": "충청", "충청본부": "충청",
    "서부": "서부", "서부본부": "서부", "전북": "서부", "전남": "서부",
    "수도권": "수도권",
}

_IRR_DB_COLS = [
    "year", "region", "skt본부", "주차별", "월", "허가번호", "통합시설코드", "호출명칭",
    "주소", "기지국구분", "시스템", "검사년도", "검사종류", "검사일자", "ons팀", "수검자",
    "전파진흥원", "검사관", "진행여부", "합불여부", "성능서류", "부적합", "불합격내용",
    "불합격상세", "부적합내용",
    "공용화대상", "기타사항", "간략불합격", "five_g_path", "장비타입", "허가번호2",
    "허가번호text", "제조주소명", "제조정보명", "검사지표정보명", "제조Type", "장비명",
    "NAMS기타정보", "장비Type공용화", "NAMS설명정보", "장비Type2", "장비타입간소화", "uploaded_by", "uploaded_at",
]


# 검사일자는 결과장 버전마다 표기가 흔들려 왔다 — 엑셀 시리얼('46028'),
# datetime('2026-01-19 00:00:00', V12부터), 'YYYY/MM/DD', 'YYYYMMDD'.
# 저장 형식을 'YYYY-MM-DD' 하나로 고정한다(kca 미러 수신측 _to_ymd 와 동일 정책).
# 읽지 못하는 값('#N/A', '1월1주', '03/03~03/06' 등)은 원문을 그대로 남긴다.
_IRR_EXCEL_EPOCH = datetime(1899, 12, 30)


def _irr_to_ymd(s: str) -> str:
    s = (s or "").strip()
    if not s:
        return ""
    if s.isdigit():
        n = int(s)
        if len(s) == 8 and 19000101 <= n <= 21001231:      # 20260119
            return f"{s[:4]}-{s[4:6]}-{s[6:8]}"
        if 20000 <= n <= 60000:                            # 엑셀 시리얼
            return (_IRR_EXCEL_EPOCH + timedelta(days=n)).strftime("%Y-%m-%d")
        return s
    m = re.match(r"\s*(\d{4})[-./](\d{1,2})[-./](\d{1,2})", s)
    if m:
        return f"{int(m.group(1)):04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    return s


def _simplify_eqp_by_keyword(raw: str) -> str:
    upper = raw.upper()
    for keyword, simplified in _EQP_KEYWORD_RULES:
        if keyword.upper() in upper:
            return simplified
    return ""


def _parse_irr_xlsx_sync(file_bytes: bytes, year_hint: int, uploaded_by: str):
    """검사실적 RAW DATA xlsx 파싱 → (rows, region, year) 반환."""
    import re as _re_wk
    wb = openpyxl.load_workbook(io.BytesIO(file_bytes), read_only=True, data_only=True)
    target_ws = None
    for name in wb.sheetnames:
        if "RAW" in name.upper():
            target_ws = wb[name]
            break
    if target_ws is None:
        for name in wb.sheetnames:
            ws = wb[name]
            for row in ws.iter_rows(min_row=1, max_row=2, values_only=True):
                if any('허가번호' in str(c or '') for c in row):
                    target_ws = wb[name]
                    break
            if target_ws is not None:
                break
    if target_ws is None:
        wb.close()
        raise ValueError("RAW DATA 시트를 찾을 수 없습니다")

    rows_iter = target_ws.iter_rows(values_only=True)
    header_row = next(rows_iter, None)
    if header_row is None:
        wb.close()
        raise ValueError("빈 시트입니다")

    headers = [str(h).strip().split('\n')[0].strip() if h else "" for h in header_row]
    if not any('허가번호' in hh for hh in headers):
        header_row = next(rows_iter, None)
        if header_row is None:
            wb.close()
            raise ValueError("헤더를 찾을 수 없습니다")
        headers = [str(h).strip().split('\n')[0].strip() if h else "" for h in header_row]

    # 첫 줄 매칭 실패 시 폴백용 — 개행·공백을 모두 제거한 전체 헤더.
    #   '장비Type\n간소화' → '장비Type간소화'
    # 첫 줄만 보면 AM열이 AJ열 단독 '장비Type'과 구별되지 않는다.
    headers_full = ["".join(str(h).split()) if h else "" for h in header_row]

    col_map = {}
    ons_idx = -1
    year_idx = -1
    hn_count = 0
    for i, h in enumerate(headers):
        if not h:
            continue
        if h == "허가번호":
            hn_count += 1
            if hn_count == 1:
                col_map["허가번호"] = i
            else:
                col_map["허가번호2"] = i
            continue
        h_clean = h.replace("Ʈ", "T").replace("Ʈ", "T")
        h_nospace = h_clean.replace(" ", "")
        h_full = (headers_full[i] if i < len(headers_full) else "").replace("Ʈ", "T")
        matched = False
        for excel_h, db_col in _IRR_HEADER_MAP.items():
            if db_col is None:
                continue
            excel_h_clean = excel_h.replace("Ʈ", "T").replace("Ʈ", "T")
            excel_h_nospace = excel_h_clean.replace(" ", "")
            if (h == excel_h or h_clean == excel_h_clean
                    or h_nospace == excel_h_nospace
                    or (h_full and h_full == excel_h_nospace)):
                if db_col == "_ons본부":
                    ons_idx = i
                elif db_col == "검사년도":
                    year_idx = i
                    col_map[db_col] = i
                else:
                    col_map[db_col] = i
                matched = True
                break

    if "장비타입" not in col_map:
        _mapped_indices = set(col_map.values())
        if ons_idx >= 0:
            _mapped_indices.add(ons_idx)
        _eqp_keywords = {"MIBOS", "RRU", "AAU", "IRO", "RHU", "RHH", "PRU", "DUO", "SF-", "RO-", "GIRO", "WAFMC"}
        _probe_rows = []
        for _pr in rows_iter:
            if _pr is None or all(c is None or str(c).strip() == "" for c in _pr):
                continue
            _probe_rows.append(_pr)
            if len(_probe_rows) >= 5:
                break
        for ci in range(len(headers)):
            if ci in _mapped_indices:
                continue
            hits = 0
            for _pr in _probe_rows:
                if ci < len(_pr) and _pr[ci]:
                    val = str(_pr[ci]).strip().upper()
                    if any(kw in val for kw in _eqp_keywords):
                        hits += 1
            if hits >= 2:
                col_map["장비타입"] = ci
                logger.info(f"장비타입 컬럼 자동감지: Col {ci} (헤더: '{headers[ci] if ci < len(headers) else ''}')")
                break
        rows_iter = itertools.chain(_probe_rows, rows_iter)

    now_str = datetime.now(timezone.utc).isoformat()
    db_rows = []
    region_set = set()

    _zpcode_eqp_map = {}
    _permit_eqp_map = {}
    if _cert_cache_db_path and os.path.exists(_cert_cache_db_path):
        try:
            cc = sqlite3.connect(_cert_cache_db_path, timeout=10)
            for _r in cc.execute("SELECT zpcode, zpwino, eqp_type FROM cert WHERE eqp_type IS NOT NULL AND eqp_type != ''"):
                eqp = str(_r[2]).strip()
                zp = str(_r[0] or "").strip()
                permit = str(_r[1] or "").strip().replace("-", "")
                if zp:
                    _zpcode_eqp_map[zp] = eqp
                if permit:
                    _permit_eqp_map[permit] = eqp
            cc.close()
            logger.info(f"장비타입 매핑 로드: zpcode={len(_zpcode_eqp_map)}, permit={len(_permit_eqp_map)}")
        except Exception:
            pass

    for row in rows_iter:
        if row is None or all(c is None or str(c).strip() == "" for c in row):
            continue

        rec = {}
        for db_col, ci in col_map.items():
            if ci < len(row):
                val = row[ci]
                rec[db_col] = str(val).strip() if val is not None else ""
            else:
                rec[db_col] = ""

        rec["검사일자"] = _irr_to_ymd(rec.get("검사일자", ""))

        region = ""
        if ons_idx >= 0 and ons_idx < len(row) and row[ons_idx]:
            ons_val = str(row[ons_idx]).strip()
            for k, v in _ONS_REGION_MAP.items():
                if k in ons_val:
                    region = v
                    break
            if not region:
                cleaned = ons_val.replace("본부", "").replace("Access", "").replace("access", "").strip()
                region = _ONS_REGION_MAP.get(cleaned, cleaned)
        rec["region"] = region
        region_set.add(region)

        auto_val = rec.pop("_이월구분_auto", "")
        if auto_val:
            cleaned = auto_val.replace("년", "").replace("년도", "").strip()
            try:
                int(float(cleaned))
                if not rec.get("검사년도"):
                    rec["검사년도"] = auto_val
            except (ValueError, TypeError):
                if not rec.get("검사종류"):
                    rec["검사종류"] = auto_val

        rec["year"] = year_hint

        if not rec.get("검사종류"):
            try:
                raw_yr = rec.get("검사년도", "").replace("년", "").replace("년도", "").strip()
                insp_yr = int(float(raw_yr))
                if insp_yr > 9999:
                    insp_yr = int(str(insp_yr)[:4])
                rec["검사종류"] = "시기조정" if insp_yr > year_hint else "정기"
            except (ValueError, TypeError):
                rec["검사종류"] = "정기"

        week = rec.get("주차별", "").strip().replace(" ", "")
        _wk_match = _re_wk.search(r'(\d{1,2})월(\d)주', week)
        if _wk_match:
            week = f"{_wk_match.group(1)}월{_wk_match.group(2)}주"
        elif week and '주' in week and '월' not in week:
            _jw_match = _re_wk.search(r'(\d)주', week)
            if _jw_match:
                ju = _jw_match.group(1)
                month = ""
                월_val = rec.get("월", "").strip().replace("월", "").strip()
                if 월_val:
                    try:
                        month = str(int(월_val))
                    except Exception:
                        pass
                if not month:
                    date_str = str(rec.get("검사일자", "")).strip()
                    try:
                        if '-' in date_str:
                            month = str(int(date_str.split('-')[1]))
                        elif '/' in date_str:
                            month = str(int(date_str.split('/')[1]))
                    except Exception:
                        pass
                if month:
                    week = f"{month}월{ju}주"
                else:
                    week = ""
        else:
            if week and not _re_wk.match(r'^\d{1,2}월\d주$', week):
                week = ""
        rec["주차별"] = week

        raw_eqp = rec.get("장비타입", "").strip()
        # 결과장 AM열에 이미 간소화 값이 적혀 있으면 그것을 그대로 쓴다(작성자가
        # 판단한 값이 파생 추론보다 정확하다). '#N/A' 같은 엑셀 오류값은 걸러낸다.
        sheet_simplified = rec.get("장비타입간소화", "").strip()
        if sheet_simplified.upper().startswith("#N/A") or sheet_simplified in ("0", "-"):
            sheet_simplified = ""
        simplified = sheet_simplified
        eqp_from_cert = ""
        eqp_from_permit = ""

        if not simplified and raw_eqp:
            simplified = _EQP_TYPE_SIMPLIFY.get(raw_eqp, "")
            if not simplified:
                for k, v in _EQP_TYPE_SIMPLIFY.items():
                    if raw_eqp.startswith(k) or k.startswith(raw_eqp):
                        simplified = v
                        break

        if not simplified:
            zpcode = rec.get("통합시설코드", "").strip()
            eqp_from_cert = _zpcode_eqp_map.get(zpcode, "") if zpcode else ""
            if eqp_from_cert:
                simplified = _EQP_TYPE_SIMPLIFY.get(eqp_from_cert, "")
                if not simplified:
                    for k, v in _EQP_TYPE_SIMPLIFY.items():
                        if eqp_from_cert.startswith(k) or k.startswith(eqp_from_cert):
                            simplified = v
                            break

        if not simplified:
            permit = rec.get("허가번호", "").strip().replace("-", "")
            eqp_from_permit = _permit_eqp_map.get(permit, "") if permit else ""
            if eqp_from_permit:
                simplified = _EQP_TYPE_SIMPLIFY.get(eqp_from_permit, "")
                if not simplified:
                    for k, v in _EQP_TYPE_SIMPLIFY.items():
                        if eqp_from_permit.startswith(k) or k.startswith(eqp_from_permit):
                            simplified = v
                            break
                if not raw_eqp:
                    rec["장비타입"] = eqp_from_permit

        if not simplified:
            for candidate in [raw_eqp, eqp_from_cert, eqp_from_permit]:
                if candidate:
                    simplified = _simplify_eqp_by_keyword(candidate)
                    if simplified:
                        break

        if not simplified:
            permit = rec.get("허가번호", "").strip()
            zpcode = rec.get("통합시설코드", "").strip()
            logger.warning(f"장비타입간소화 최종 실패: 허가번호='{permit}', zpcode='{zpcode}', raw_eqp='{raw_eqp}'")

        rec["장비타입간소화"] = simplified
        rec["uploaded_by"] = uploaded_by
        rec["uploaded_at"] = now_str
        db_rows.append(rec)

    wb.close()
    if region_set:
        primary_region = max(region_set, key=lambda r: sum(1 for d in db_rows if d.get("region") == r))
    else:
        primary_region = ""

    return db_rows, primary_region, year_hint


def _irr_dashboard_calc_sync(year: int, region: str = "", month: str = "", team: str = "", group_by: str = ""):
    """검사실적 대시보드 집계 (동기).

    그룹화 규칙:
    - group_by="" + region="" → 본부 단위 (기본)
    - group_by="" + region 지정 → 본부 한 곳 단일 집계
    - group_by="team" + region 지정 → 그 본부의 팀별(ons팀) 집계
    - team 지정 → 그 팀 한 곳 단일 집계 (group_by 무시)
    """
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    try:
        base_where = "year=?"
        params: list = [year]
        if region:
            base_where += " AND region=?"
            params.append(region)
        if month:
            base_where += " AND 월=?"
            params.append(month)
        if team:
            base_where += " AND ons팀=?"
            params.append(team)

        # 그룹 키 결정
        if team:
            group_keys = [team]
            key_mode = "team"
        elif group_by == "team" and region:
            group_keys = [r[0] for r in conn.execute(
                f"SELECT DISTINCT ons팀 FROM inspection_results_raw WHERE {base_where} "
                f"AND ons팀 IS NOT NULL AND ons팀<>'' ORDER BY ons팀",
                params
            ).fetchall()]
            key_mode = "team"
        else:
            group_keys = [r[0] for r in conn.execute(
                f"SELECT DISTINCT region FROM inspection_results_raw WHERE {base_where} ORDER BY region",
                params
            ).fetchall()]
            key_mode = "region"

        result_regions = []
        for gk in group_keys:
            if team:
                rg_where = base_where
                rg_params = list(params)
            elif key_mode == "team":
                rg_where = base_where + " AND ons팀=?"
                rg_params = list(params) + [gk]
            else:
                # 본부 단위 — region 없을 때는 base_where에 region이 없으므로 추가
                if region:
                    rg_where = base_where
                    rg_params = list(params)
                else:
                    rg_where = "year=? AND region=?"
                    rg_params = [year, gk]
                    if month:
                        rg_where += " AND 월=?"
                        rg_params.append(month)

            수검국소 = conn.execute(
                f'SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where}', rg_params
            ).fetchone()[0]

            시기조정 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 검사종류 LIKE '%시기조정%'",
                rg_params
            ).fetchone()[0]

            폐 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 기타사항 LIKE '%폐국%'",
                rg_params
            ).fetchone()[0]

            성능불합격 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 성능서류='성능'",
                rg_params
            ).fetchone()[0]

            서류불합격 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 성능서류='서류'",
                rg_params
            ).fetchone()[0]

            완료 = 수검국소 - 시기조정
            성능합격 = 수검국소 - 성능불합격
            서류합격 = 수검국소 - 서류불합격

            result_regions.append({
                "name": gk,
                "수검국소": 수검국소,
                "완료": 완료,
                "시기조정": 시기조정,
                "폐": 폐,
                "성능합격": 성능합격,
                "성능불합격": 성능불합격,
                "서류검사": 수검국소,
                "서류합격": 서류합격,
                "서류불합격": 서류불합격,
                "성능합격율": round(성능합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "성능불합격율": round(성능불합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "서류합격율": round(서류합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "서류불합격율": round(서류불합격 / 수검국소, 4) if 수검국소 > 0 else 0,
            })

        t_수검 = sum(r["수검국소"] for r in result_regions)
        t_시기 = sum(r["시기조정"] for r in result_regions)
        t_폐 = sum(r["폐"] for r in result_regions)
        t_성능불 = sum(r["성능불합격"] for r in result_regions)
        t_서류불 = sum(r["서류불합격"] for r in result_regions)
        t_완료 = t_수검 - t_시기
        t_성능합 = t_수검 - t_성능불
        t_서류합 = t_수검 - t_서류불

        total = {
            "name": "합계",
            "수검국소": t_수검,
            "완료": t_완료,
            "시기조정": t_시기,
            "폐": t_폐,
            "성능합격": t_성능합,
            "성능불합격": t_성능불,
            "서류검사": t_수검,
            "서류합격": t_서류합,
            "서류불합격": t_서류불,
            "성능합격율": round(t_성능합 / t_수검, 4) if t_수검 > 0 else 0,
            "성능불합격율": round(t_성능불 / t_수검, 4) if t_수검 > 0 else 0,
            "서류합격율": round(t_서류합 / t_수검, 4) if t_수검 > 0 else 0,
            "서류불합격율": round(t_서류불 / t_수검, 4) if t_수검 > 0 else 0,
        }

        try:
            target_전체 = conn.execute('SELECT COUNT(*) FROM inspection_targets WHERE year=?', (year,)).fetchone()[0]
        except Exception:
            target_전체 = 0
        target = {
            "전체": target_전체,
            "정기검사": target_전체,
            "시기조정": 0,
            "미이행": max(0, target_전체 - t_수검),
        }

        # 최근 업로드 일시 (연도 기준)
        last_upload = ""
        try:
            row = conn.execute(
                'SELECT MAX(uploaded_at) FROM inspection_results_raw WHERE year=?', [year]
            ).fetchone()
            if row and row[0]:
                last_upload = row[0][:10]  # "YYYY-MM-DD"
            elif result_regions:
                # uploaded_at 없는 구 데이터 → DB 파일 수정 시각으로 폴백
                import datetime as _dt
                mtime = os.path.getmtime(_INSP_DB)
                last_upload = _dt.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d')
        except Exception:
            pass

        resolved_group_by = "team" if (team or (group_by == "team" and region)) else "region"
        return {
            "regions": result_regions,
            "total": total,
            "target": target,
            "last_upload": last_upload,
            "groupBy": resolved_group_by,
        }
    finally:
        conn.close()


class InspectionResultsExportReq(BaseModel):
    year: int
    본부: Union[str, List[str]] = ""
    진행여부: str = ""
    status: str = ""
    성능서류: str = ""
    주차별: Union[str, List[str]] = ""


@router.post("/inspection-results/upload")
async def inspection_results_upload(request: Request, file: UploadFile = File(...)):
    """검사실적 RAW DATA xlsx 업로드 (admin/manager)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    if not HAS_OPENPYXL:
        raise HTTPException(500, "openpyxl 미설치")

    fname = file.filename or ""
    if fname.lower().endswith('.xls') and not fname.lower().endswith('.xlsx'):
        raise HTTPException(400, ".xls 형식은 지원하지 않습니다. xlsx 파일로 변환 후 업로드해주세요.")

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일입니다")

    year_hint = datetime.now().year

    try:
        db_rows, primary_region, year = await asyncio.to_thread(
            _parse_irr_xlsx_sync, file_bytes, year_hint, empno
        )
    except ValueError as ve:
        raise HTTPException(400, str(ve))
    finally:
        del file_bytes

    if not db_rows:
        raise HTTPException(400, "파싱된 데이터가 없습니다")

    def _insert_sync():
        _init_inspection_db()
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            regions = set(r.get("region", "") for r in db_rows)
            years = set(r.get("year", year) for r in db_rows)
            for rg in regions:
                for yr in years:
                    conn.execute(
                        'DELETE FROM inspection_results_raw WHERE region=? AND year=?',
                        (rg, yr)
                    )
            placeholders = ','.join(['?'] * len(_IRR_DB_COLS))
            sql = f'INSERT INTO inspection_results_raw ({",".join(_IRR_DB_COLS)}) VALUES ({placeholders})'
            batch = []
            for rec in db_rows:
                vals = tuple(rec.get(c, "") for c in _IRR_DB_COLS)
                batch.append(vals)
            conn.executemany(sql, batch)
            conn.commit()
            return len(batch)
        finally:
            conn.close()

    count = await asyncio.to_thread(_insert_sync)
    return {"success": True, "count": count, "region": primary_region}


@router.get("/inspection-results/dashboard")
async def inspection_results_dashboard(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
    groupBy: str = Query(""),
):
    """검사실적 대시보드 — 지역별 합격/불합격 집계.

    파라미터:
    - region: 본부 필터 (예: '강남')
    - team: 팀 필터 (예: '평택품질개선팀')
    - groupBy='team' + region 지정 → 그 본부의 팀별 분해
    """
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"regions": [], "total": {}, "target": {}, "groupBy": "region"}
    return await asyncio.to_thread(
        _irr_dashboard_calc_sync, year, region=region, team=team, group_by=groupBy
    )


@router.get("/inspection-results/dashboard/monthly")
async def inspection_results_dashboard_monthly(
    request: Request,
    year: int = Query(...),
    month: str = Query(""),
    region: str = Query(""),
    team: str = Query(""),
    groupBy: str = Query(""),
):
    """검사실적 월별 대시보드."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"regions": [], "total": {}, "target": {}, "groupBy": "region"}
    return await asyncio.to_thread(
        _irr_dashboard_calc_sync, year, region=region, month=month, team=team, group_by=groupBy
    )


@router.get("/inspection-results/trend")
async def inspection_results_trend(request: Request, year: int = Query(...)):
    """검사실적 월별 트렌드 (차트용)."""
    await _verify_auth(request)

    def _trend_sync():
        if not os.path.exists(_INSP_DB):
            return {"months": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            rows = conn.execute(
                "SELECT 월, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                "FROM inspection_results_raw WHERE year=? AND 월 IS NOT NULL AND 월 != '' "
                "GROUP BY 월 ORDER BY 월",
                (year,)
            ).fetchall()
            months = []
            for r in rows:
                월, cnt, 성능불, 서류불 = r
                성능합 = cnt - 성능불
                서류합 = cnt - 서류불
                months.append({
                    "월": 월,
                    "수검국소": cnt,
                    "성능합격율": round(성능합 / cnt, 4) if cnt > 0 else 0,
                    "서류합격율": round(서류합 / cnt, 4) if cnt > 0 else 0,
                })
            return {"months": months}
        finally:
            conn.close()

    return await asyncio.to_thread(_trend_sync)


@router.get("/inspection-results/raw")
async def inspection_results_raw_list(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    월: str = Query(""),
    page: int = Query(1),
    pageSize: int = Query(100),
):
    """검사실적 RAW DATA 목록 (페이징)."""
    await _verify_auth(request)

    def _list_sync():
        if not os.path.exists(_INSP_DB):
            return {"items": [], "total": 0}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        try:
            where = "year=?"
            params: list = [year]
            if region:
                where += " AND region=?"
                params.append(region)
            if 월:
                where += " AND 월=?"
                params.append(월)

            total = conn.execute(
                f'SELECT COUNT(*) FROM inspection_results_raw WHERE {where}', params
            ).fetchone()[0]

            offset = (max(1, page) - 1) * pageSize
            items = conn.execute(
                f'SELECT * FROM inspection_results_raw WHERE {where} ORDER BY id LIMIT ? OFFSET ?',
                params + [pageSize, offset]
            ).fetchall()

            return {
                "items": [dict(r) for r in items],
                "total": total,
            }
        finally:
            conn.close()

    return await asyncio.to_thread(_list_sync)


@router.get("/inspection-results/analysis")
async def inspection_results_analysis(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
):
    """불합격 사유 분석 (성능/서류/장비타입별).

    team 지정 시 inspection_targets와 JOIN해서 그 팀에 속한 허가번호만 집계.
    """
    await _verify_auth(request)

    def _analysis():
        if not os.path.exists(_INSP_DB):
            return {"성능불합격": [], "서류불합격": [], "장비타입별": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            base_where = "year=?"
            base_params: list = [year]
            if region:
                base_where += " AND region=?"
                base_params.append(region)
            if team:
                base_where += " AND ons팀=?"
                base_params.append(team)

            perf_rows = conn.execute(
                f"SELECT 간략불합격, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE {base_where} AND 성능서류='성능' "
                f"AND 간략불합격 IS NOT NULL AND 간략불합격 != '' "
                f"GROUP BY 간략불합격 ORDER BY cnt DESC",
                base_params
            ).fetchall()
            perf_total = sum(r[1] for r in perf_rows) or 1
            성능불합격 = [{"사유": r[0], "건수": r[1], "비율": round(r[1]/perf_total, 4)} for r in perf_rows]

            doc_rows = conn.execute(
                f"SELECT 간략불합격, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE {base_where} AND 성능서류='서류' "
                f"AND 간략불합격 IS NOT NULL AND 간략불합격 != '' "
                f"GROUP BY 간략불합격 ORDER BY cnt DESC",
                base_params
            ).fetchall()
            doc_total = sum(r[1] for r in doc_rows) or 1
            서류불합격 = [{"사유": r[0], "건수": r[1], "비율": round(r[1]/doc_total, 4)} for r in doc_rows]

            equip_rows = conn.execute(
                f"SELECT 장비타입간소화, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE {base_where} AND 성능서류='성능' "
                f"AND 장비타입간소화 IS NOT NULL AND 장비타입간소화 != '' "
                f"GROUP BY 장비타입간소화 ORDER BY cnt DESC",
                base_params
            ).fetchall()
            equip_total = sum(r[1] for r in equip_rows) or 1
            장비타입별 = [{"타입": r[0], "건수": r[1], "비율": round(r[1]/equip_total, 4)} for r in equip_rows]

            top3_types = [r["타입"] for r in 장비타입별[:3]]
            crosstab = []
            # 크로스탭은 본부 단위 비교용이라 team 지정 시 의미가 없어 생략
            if top3_types and not team:
                placeholders = ",".join("?" for _ in top3_types)
                ct_params = list(base_params) + top3_types
                ct_rows = conn.execute(
                    f"SELECT 장비타입간소화, region, COUNT(*) as cnt FROM inspection_results_raw "
                    f"WHERE {base_where} AND 성능서류='성능' "
                    f"AND 장비타입간소화 IN ({placeholders}) "
                    f"AND 장비타입간소화 IS NOT NULL AND 장비타입간소화 != '' "
                    f"GROUP BY 장비타입간소화, region ORDER BY 장비타입간소화",
                    ct_params
                ).fetchall()
                pivot: Dict[str, Dict[str, int]] = {}
                for typ, reg, cnt in ct_rows:
                    pivot.setdefault(typ, {})[reg or "기타"] = cnt
                all_regions = [r[0] for r in conn.execute(
                    "SELECT DISTINCT region FROM inspection_results_raw WHERE year=? AND region != ''", (year,)).fetchall()]
                for typ in top3_types:
                    row_data = {rg: pivot.get(typ, {}).get(rg, 0) for rg in all_regions}
                    total_ct = sum(row_data.values())
                    crosstab.append({"타입": typ, "본부별": row_data, "총합계": total_ct})
                total_rows = conn.execute(
                    f"SELECT region, COUNT(*) FROM inspection_results_raw "
                    f"WHERE {base_where} AND 성능서류='성능' AND region != '' "
                    f"GROUP BY region",
                    base_params
                ).fetchall()
                total_row = {rg: cnt for rg, cnt in total_rows}
                crosstab.append({"타입": "성능불합격(건)", "본부별": total_row, "총합계": sum(total_row.values())})

            return {"성능불합격": 성능불합격, "서류불합격": 서류불합격, "장비타입별": 장비타입별, "장비타입별_크로스탭": crosstab}
        finally:
            conn.close()

    return await asyncio.to_thread(_analysis)


@router.get("/inspection-results/weekly-trend")
async def inspection_results_weekly_trend(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
):
    """주차별 합격율 추이."""
    await _verify_auth(request)

    def _weekly():
        if not os.path.exists(_INSP_DB):
            return {"weeks": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            where = "year=?"
            params: list = [year]
            if region:
                where += " AND region=?"
                params.append(region)
            if team:
                where += " AND ons팀=?"
                params.append(team)
            rows = conn.execute(
                "SELECT 주차별, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                f"FROM inspection_results_raw WHERE {where} AND 주차별 IS NOT NULL AND 주차별 != '' "
                "GROUP BY 주차별 ORDER BY 주차별",
                params
            ).fetchall()
            weeks = []
            for r in rows:
                주차, cnt, 성능불, 서류불 = r
                weeks.append({
                    "주차": 주차,
                    "수검": cnt,
                    "불합격": 성능불,
                    "합격율": round((cnt - 성능불) / cnt, 4) if cnt > 0 else 0,
                    "서류불합격": 서류불,
                    "서류합격율": round((cnt - 서류불) / cnt, 4) if cnt > 0 else 0,
                })
            return {"weeks": weeks}
        finally:
            conn.close()

    return await asyncio.to_thread(_weekly)


@router.get("/inspection-results/weekly-trend-by-region")
async def inspection_results_weekly_trend_by_region(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
):
    """본부별 또는 팀별 주차별 합격율 추이 (소형 차트용).

    region 비어있음 → 본부 9개 차트
    region 지정 → 그 본부에 속한 팀들(ons팀)의 차트로 자동 전환
    응답 키는 'regions' 유지(프론트 호환), groupBy 필드로 구분.
    """
    await _verify_auth(request)

    def _by_group():
        if not os.path.exists(_INSP_DB):
            return {"regions": {}, "groupBy": "region"}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            if region:
                # 본부 선택됨 → ons팀 단위로 분해
                rows = conn.execute(
                    "SELECT ons팀, 주차별, COUNT(*) as cnt, "
                    "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                    "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                    "FROM inspection_results_raw "
                    "WHERE year=? AND region=? AND 주차별 IS NOT NULL AND 주차별 != '' "
                    "AND ons팀 IS NOT NULL AND ons팀 != '' "
                    "GROUP BY ons팀, 주차별 ORDER BY ons팀, 주차별",
                    (year, region)
                ).fetchall()
                resolved = "team"
            else:
                rows = conn.execute(
                    "SELECT region, 주차별, COUNT(*) as cnt, "
                    "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                    "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                    "FROM inspection_results_raw "
                    "WHERE year=? AND 주차별 IS NOT NULL AND 주차별 != '' AND region IS NOT NULL AND region != '' "
                    "GROUP BY region, 주차별 ORDER BY region, 주차별",
                    (year,)
                ).fetchall()
                resolved = "region"

            groups: Dict[str, list] = {}
            for key, 주차, cnt, 성능불, 서류불 in rows:
                groups.setdefault(key, []).append({
                    "주차": 주차,
                    "합격율": round((cnt - 성능불) / cnt, 4) if cnt > 0 else 0,
                    "서류합격율": round((cnt - 서류불) / cnt, 4) if cnt > 0 else 0,
                })
            return {"regions": groups, "groupBy": resolved}
        finally:
            conn.close()

    return await asyncio.to_thread(_by_group)


@router.get("/inspection-results/summary-report")
async def inspection_results_summary_report(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
):
    """실적 현황 리포트 자동 생성."""
    await _verify_auth(request)

    def _build_report():
        if not os.path.exists(_INSP_DB):
            return {"lines": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            base_where = "year=?"
            base_params: list = [year]
            if region:
                base_where += " AND region=?"
                base_params.append(region)
            if team:
                base_where += " AND ons팀=?"
                base_params.append(team)
            total = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE {base_where}", base_params).fetchone()[0]
            if total == 0:
                return {"lines": ["데이터가 없습니다."]}

            perf_fail = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE {base_where} AND 성능서류='성능'", base_params).fetchone()[0]
            doc_fail = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE {base_where} AND 성능서류='서류'", base_params).fetchone()[0]
            perf_pass = total - perf_fail
            doc_pass = total - doc_fail
            perf_rate = round(perf_pass / total * 100, 1) if total > 0 else 0
            doc_rate = round(doc_pass / total * 100, 1) if total > 0 else 0
            perf_target = 98.5
            doc_target = 85.5
            perf_diff = round(perf_rate - perf_target, 1)
            doc_diff = round(doc_rate - doc_target, 1)

            lines = []

            perf_status = "달성중" if perf_diff >= 0 else "미달성중"
            doc_status = "달성중" if doc_diff >= 0 else "미달성중"
            perf_arrow = "↑" if perf_diff >= 0 else "↓"
            doc_arrow = "↑" if doc_diff >= 0 else "↓"
            lines.append({
                "type": "header",
                "text": f"○ '{year % 100}년 무선국 합격율 실적(누적)"
            })
            lines.append({
                "type": "perf_ok" if perf_diff >= 0 else "perf_fail",
                "text": f"   성능 {perf_rate}% (목표 대비 {abs(perf_diff)}%{perf_arrow}) {perf_status}"
            })
            lines.append({
                "type": "doc_ok" if doc_diff >= 0 else "doc_fail",
                "text": f"   서류 {doc_rate}% (목표 대비 {abs(doc_diff)}%{doc_arrow}) {doc_status}"
            })

            weeks = conn.execute(
                "SELECT 주차별, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                "FROM inspection_results_raw WHERE year=? AND 주차별 IS NOT NULL AND 주차별 != '' "
                "GROUP BY 주차별 ORDER BY 주차별",
                (year,)
            ).fetchall()

            if len(weeks) >= 2:
                curr_week = weeks[-1]
                prev_week = weeks[-2]
                curr_rate = round((curr_week[1] - curr_week[2]) / curr_week[1] * 100, 1) if curr_week[1] > 0 else 0
                prev_rate = round((prev_week[1] - prev_week[2]) / prev_week[1] * 100, 1) if prev_week[1] > 0 else 0
                diff = round(curr_rate - prev_rate, 1)
                direction = "상승" if diff >= 0 else "하락"
                lines.append({
                    "type": "detail",
                    "text": f" - 성능합격율 : {curr_week[0]} {curr_rate}%로 전주대비 {abs(diff)}% {direction}({prev_rate}% → {curr_rate}%)"
                })

            if len(weeks) >= 2:
                curr_wk_name = weeks[-1][0]
                prev_wk_name = weeks[-2][0]

                regions_curr = conn.execute(
                    "SELECT region, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                    "FROM inspection_results_raw WHERE year=? AND 주차별=? GROUP BY region",
                    (year, curr_wk_name)
                ).fetchall()
                regions_prev = conn.execute(
                    "SELECT region, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                    "FROM inspection_results_raw WHERE year=? AND 주차별=? GROUP BY region",
                    (year, prev_wk_name)
                ).fetchall()

                prev_map = {r[0]: (r[1], r[2]) for r in regions_prev}
                drops = []
                for r in regions_curr:
                    rg, cnt, fail = r
                    curr_r = round((cnt - fail) / cnt * 100, 1) if cnt > 0 else 0
                    if rg in prev_map:
                        p_cnt, p_fail = prev_map[rg]
                        prev_r = round((p_cnt - p_fail) / p_cnt * 100, 1) if p_cnt > 0 else 0
                        d = round(curr_r - prev_r, 1)
                        if d < 0:
                            drops.append((rg, curr_r, abs(d), fail))

                if drops:
                    drops.sort(key=lambda x: -x[2])
                    drop_texts = [f"{rg} {rate}% {drop}%하락(성능불합격 {fail}국)" for rg, rate, drop, fail in drops[:3]]
                    lines.append({
                        "type": "sub",
                        "text": f"   → 전주대비 하락 Acc.담당 : {', '.join(drop_texts)}"
                    })

            동작불능 = conn.execute(
                "SELECT region, COUNT(*) FROM inspection_results_raw WHERE year=? AND 불합격내용 LIKE '%동작불능%' GROUP BY region",
                (year,)
            ).fetchall()
            if 동작불능:
                total_불능 = sum(r[1] for r in 동작불능)
                detail = ', '.join(f"{r[0]} {r[1]}국" for r in 동작불능)
                lines.append({
                    "type": "sub",
                    "text": f"   → 동작 불능 {total_불능}국 발생 : {detail}"
                })

            region_stats = conn.execute(
                "SELECT region, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as perf_fail, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as doc_fail "
                "FROM inspection_results_raw WHERE year=? AND region != '' GROUP BY region ORDER BY region",
                (year,)
            ).fetchall()

            ranked = []
            for r in region_stats:
                rg, cnt, pf, df = r
                p_rate = round((cnt - pf) / cnt * 100, 1) if cnt > 0 else 0
                d_rate = round((cnt - df) / cnt * 100, 1) if cnt > 0 else 0
                ranked.append((rg, p_rate, d_rate))
            ranked.sort(key=lambda x: x[1], reverse=True)

            if ranked:
                perf_text = " > ".join(f"{rg} {pr}%" for rg, pr, _ in ranked)
                lines.append({
                    "type": "detail",
                    "text": f" - Acc.담당 누적 실적 (성능)\n   → {perf_text}순"
                })
                doc_ranked = sorted(ranked, key=lambda x: x[2], reverse=True)
                doc_text = " > ".join(f"{rg} {dr}%" for rg, _, dr in doc_ranked)
                lines.append({
                    "type": "detail",
                    "text": f" - Acc.담당 누적 실적 (서류)\n   → {doc_text}순"
                })

            if perf_rate < perf_target and len(weeks) > 0:
                remaining_weeks = 52 - len(weeks)
                if remaining_weeks > 0:
                    needed_rate = round(perf_target + (perf_target - perf_rate) * len(weeks) / remaining_weeks, 1)
                    needed_max_fail = max(0, int(total / len(weeks) * (1 - needed_rate / 100)))
                    lines.append({
                        "type": "highlight",
                        "text": f"   ☞ 목표 달성 위해 주단위 {min(needed_rate, 99.9)}%이상 달성시 (주단위 불합격 {needed_max_fail}국 이하) 달성으로 전환 가능"
                    })

            return {"lines": lines}
        finally:
            conn.close()

    return await asyncio.to_thread(_build_report)


@router.get("/inspection-results/weeks")
async def inspection_results_weeks(request: Request, year: int = Query(...), month: str = Query(""), region: str = Query("")):
    """실적 업로드된 주차 목록 조회 (월/본부 필터)."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"weeks": []}

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        where_parts = ["year=?", "주차별 IS NOT NULL", "주차별 != ''"]
        params: list = [year]
        if month:
            where_parts.append("월=?"); params.append(month)
        if region:
            where_parts.append("region=?"); params.append(region)
        rows = c.execute(
            f"SELECT DISTINCT 주차별 FROM inspection_results_raw WHERE {' AND '.join(where_parts)} ORDER BY 주차별",
            params,
        ).fetchall()
        c.close()
        return [r[0] for r in rows]

    weeks = await asyncio.to_thread(_query)
    return {"weeks": weeks}


@router.post("/inspection-results/export-xlsx")
async def inspection_results_export_xlsx(request: Request, req: InspectionResultsExportReq):
    """실적 결과장 RAW DATA Excel 내보내기."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "데이터 없음")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter

        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        _sel = (
            'SELECT r.* '
            'FROM inspection_results_raw r '
        )
        where_parts = ['r.year=?']
        params = [req.year]
        본부_list = [req.본부] if isinstance(req.본부, str) else req.본부
        본부_list = [v for v in 본부_list if v]
        if 본부_list:
            placeholders = ','.join('?' * len(본부_list))
            where_parts.append(f'r.region IN ({placeholders})')
            params.extend(본부_list)
        if req.진행여부:
            where_parts.append('r.진행여부=?'); params.append(req.진행여부)
        if req.status:
            where_parts.append('r.합불여부=?'); params.append(req.status)
        if req.성능서류:
            where_parts.append('r.성능서류=?'); params.append(req.성능서류)
        주차_list = [req.주차별] if isinstance(req.주차별, str) else req.주차별
        주차_list = [v for v in 주차_list if v]
        if 주차_list:
            placeholders = ','.join('?' * len(주차_list))
            where_parts.append(f'r.주차별 IN ({placeholders})')
            params.extend(주차_list)
        where_sql = ' AND '.join(where_parts)
        rows = c.execute(_sel + f'WHERE {where_sql} ORDER BY r.id', params).fetchall()
        c.close()

        if not rows:
            raise ValueError("조회된 실적 데이터가 없습니다")

        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "RAW DATA"

        _thin_side = Side(style='thin')
        _thin_border = Border(left=_thin_side, right=_thin_side,
                              top=_thin_side, bottom=_thin_side)
        _hdr_fill = PatternFill('solid', fgColor='FFBFBFBF')
        _hdr_font = Font(name='맑은 고딕', size=10, bold=True)
        _data_font = Font(name='맑은 고딕', size=10)
        _center = Alignment(horizontal='center', vertical='center', wrap_text=False)
        _left = Alignment(horizontal='left', vertical='center', wrap_text=False)
        _left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)
        _hdr_wrap = Alignment(horizontal='center', vertical='center', wrap_text=True)
        _hdr_left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)
        _LINE_H = 16.5

        headers = [
            '주차', '월', '구분', 'SKT본부', 'ONS 본부', '허가번호',
            '통합시설코드', '호출명칭', '주소', '기지국/중계기 여부', '시스템',
            '정기검사 년도', '정기/시기조정', '검사일자', '1. ONS(팀)', '수검자',
            '전파진흥원\n(예. 서울본부/북서울본부/경인본부 등)',
            '검사관\n(검사관 이름)', '진행여부', '합격,불합격여부', '성능/서류', '부적합', '불합격내용',
            '불합격상세사유', '부적합내용', '공용화 정비대상 유/무', '기타사항(폐국 및 대개체국소)', '간략불합격내역',
            '5G Path 확인 방법\n1. 전체 Path\n2. 부분 Path\n3. 1개 Path \n4. Total Power',
            '허가번호 장비 Type\n\n1. MIBOS(SMHS 등등)\n2. RRU\n3. AAU20-5G-AAU3.5G-64T\nAAU21-5G-AAU3.5G-32T 등\n4. 광급중계기(DDR,MPR 등)',
            '장비타입간소화',
        ]

        # V12 배치: 21 성능/서류, 22 부적합(V), 23 불합격내용, 24 불합격상세사유, 25 부적합내용(Y)
        _left_cols = {9, 24, 30}
        _left_wrap_cols = {9, 24}
        _hdr_left_cols = {30}

        _hdr_max_lines = 1
        for h in headers:
            _lc = h.count('\n') + 1
            if _lc > _hdr_max_lines:
                _hdr_max_lines = _lc
        ws.row_dimensions[1].height = _LINE_H * _hdr_max_lines

        for ci, h in enumerate(headers, 1):
            cell = ws.cell(row=1, column=ci, value=h)
            cell.font = _hdr_font
            cell.fill = _hdr_fill
            cell.border = _thin_border
            cell.alignment = _hdr_left_wrap if ci in _hdr_left_cols else _hdr_wrap

        db_cols = [
            '주차별', '월', None, 'skt본부', 'region', '허가번호',
            '통합시설코드', '호출명칭', '주소', '기지국구분', '시스템',
            '검사년도', '검사종류', '검사일자', 'ons팀', '수검자',
            '전파진흥원', '검사관', '진행여부', '합불여부', '성능서류', '부적합', '불합격내용',
            '불합격상세', '부적합내용', '공용화대상', '기타사항', '간략불합격',
            'five_g_path', '장비타입', '장비타입간소화',
        ]

        for ri, row in enumerate(rows, 2):
            d = dict(row)
            values = []
            for i, db_col in enumerate(db_cols):
                if db_col is None:
                    values.append(ri - 1)
                else:
                    values.append(d.get(db_col) or '')

            max_lines = 1
            for _v in values:
                if isinstance(_v, str) and '\n' in _v:
                    _lc = _v.count('\n') + 1
                    if _lc > max_lines:
                        max_lines = _lc
            ws.row_dimensions[ri].height = _LINE_H * max_lines

            for ci, v in enumerate(values, 1):
                cell = ws.cell(row=ri, column=ci, value=v)
                cell.font = _data_font
                cell.border = _thin_border
                cell.alignment = _left_wrap if ci in _left_wrap_cols else (_left if ci in _left_cols else _center)

        def _col_width(s):
            w = 0.0
            for ch in str(s):
                w += 2.2 if ord(ch) > 127 else 1.1
            return w

        for ci in range(1, len(headers) + 1):
            best = 0
            for ri2 in range(2, min(len(rows) + 2, 202)):
                val = ws.cell(row=ri2, column=ci).value
                if val is not None:
                    for line in str(val).split('\n'):
                        best = max(best, _col_width(line))
            max_w = 40 if ci in _left_wrap_cols else 80
            ws.column_dimensions[get_column_letter(ci)].width = max(min(best + 1, max_w), 12.25)

        ws.freeze_panes = 'I2'

        buf = io.BytesIO()
        wb.save(buf)
        wb.close()
        buf.seek(0)
        return buf.getvalue()

    try:
        data = await asyncio.to_thread(_build)
    except ValueError as e:
        logger.warning(f"inspection_results xlsx 빌드 실패: {e}")
        raise HTTPException(404, "수검 결과 데이터를 조회할 수 없습니다")

    filename = f"inspection_results_{req.year}.xlsx"
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_url_quote(filename)}"}
    )


# ══════════════════════════════════════════════════════════════════════
# kca(Playground) 미러링용 브라우저 릴레이 export
# ══════════════════════════════════════════════════════════════════════

# kca inspection_results_raw 컬럼과 1:1 (year 는 envelope, uploaded_* 는 수신측이 채움).
# ksa 전용 컬럼(허가번호2·제조*·NAMS*·장비Type2 등)은 kca 에 없으므로 제외한다.
_IRR_MIRROR_COLS = (
    'region', 'skt본부', '주차별', '월', '허가번호', '통합시설코드', '호출명칭',
    '주소', '기지국구분', '시스템', '검사년도', '검사종류', '검사일자', 'ons팀',
    '수검자', '전파진흥원', '검사관', '진행여부', '합불여부', '성능서류',
    # V12 신설 — kca inspection_results_raw 에도 동일 컬럼이 있다(키 이름이 다르면
    # kca 수신부 _KSA_MIRROR_COLS 매칭에서 조용히 버려지므로 DB 컬럼명 그대로 보낸다).
    '부적합', '부적합내용',
    '불합격내용', '불합격상세', '공용화대상', '기타사항', '간략불합격',
    'five_g_path', '장비타입', '장비타입간소화',
)

_IRR_REGIONS = ('강남', '강북', '인천', '경기', '경남', '경북', '서부', '충청', '강원')


@router.post("/inspection-results/sync-export")
async def inspection_results_sync_export(request: Request):
    """kca 실적(결과장) 미러링용 — inspection_results_raw 를 본부(region) 단위 JSON export.

    실적은 연 7만행 규모라 한 번에 넘기면 브라우저 릴레이가 타임아웃된다.
    sync-export-targets 와 동일하게 region 단위로 쪼개고, region='__ETC__' 는
    9개 본부 어디에도 속하지 않는 잔여분(빈값·수도권·오타 등)을 담는다.
    sync-export 와 동일 규격(body.secret, 단순 요청 — preflight 없음). 읽기 전용.
    """
    from routers.special_sites import KSA_SYNC_SECRET, _ingest_cors
    from core.utils import _check_rate_limit
    import hmac as _hm

    try:
        _check_rate_limit(request, "sync_export_results", 30, 60)  # region 루프 9+1회 허용
    except HTTPException as e:
        return JSONResponse({"detail": e.detail}, status_code=e.status_code,
                            headers=_ingest_cors())
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({"detail": "잘못된 요청 형식"}, status_code=400,
                            headers=_ingest_cors())
    secret = str(data.get("secret") or "")
    if not (KSA_SYNC_SECRET and secret
            and _hm.compare_digest(secret, KSA_SYNC_SECRET)):
        return JSONResponse({"detail": "unauthorized"}, status_code=401,
                            headers=_ingest_cors())
    try:
        year = int(data.get("year") or 0)
    except (TypeError, ValueError):
        year = 0
    if not year:
        return JSONResponse({"detail": "year를 지정하세요"}, status_code=400,
                            headers=_ingest_cors())
    region = str(data.get("region") or "").strip()

    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.row_factory = sqlite3.Row
        try:
            wheres, params = ['year=?'], [year]
            if region == '__ETC__':
                ph = ','.join('?' * len(_IRR_REGIONS))
                wheres.append(f"COALESCE(region,'') NOT IN ({ph})")
                params.extend(_IRR_REGIONS)
            elif region:
                wheres.append("region=?")
                params.append(region)
            rows = c.execute(
                f"SELECT {', '.join(_IRR_MIRROR_COLS)} FROM inspection_results_raw "
                f"WHERE {' AND '.join(wheres)}", params).fetchall()
            return [dict(r) for r in rows]
        finally:
            c.close()

    items = await asyncio.to_thread(_read)
    logger.info(f"실적 sync-export: year={year}, region={region or '전체'}, {len(items)}건")
    return JSONResponse({"success": True, "year": year, "region": region,
                         "items": items, "total": len(items)},
                        headers=_ingest_cors())


# ── 실적(RAW) → 수검 일정·결과 복원 (백필) ─────────────────────
#   상용화 이후 경북·인천 외 본부는 일정/결과를 시스템에 입력하지 않아 일정
#   메뉴가 비어 있다. 수검 실적은 결과장(inspection_results_raw)에 전량 쌓이므로
#   그것을 원본으로 inspection_results(수검 결과) + inspection_schedules(수검 일정)
#   이력을 복원한다. 여기(SKO 무선국)가 데이터 원본이므로 복원도 여기서 하고,
#   플레이그라운드는 기존 [SKO 무선국에서 가져오기] 미러로 전파받는다.
#
#   결과장 ↔ 일정/결과 표기 차이 변환:
#     - 허가번호: 하이픈 표기 제거 후 조인
#     - 검사일자: 엑셀 시리얼/기간('03/03~03/06')/'#N/A' → 'YYYYMMDD' (시작일)
#     - 주차별 '1월1주' → 수검예정주차 '1월 1주차'
#     - 합불여부·성능서류·공용화대상 → 결과 status 어휘
#       (성능서류='부적합'은 합불여부가 합격이어도 부적합 건)
#     - 불합격상세 → 결과 특이사항 메모
#     - 본부/팀: 대상(inspection_targets) 값 우선, 폴백은 결과장 region/ons팀을
#       표준 9본부('강남'~'강원')·표준 품질개선팀으로 정규화 ('0'/'강남Access' 등
#       비표준 값은 버린다 — 화면 필터·미러 격리가 본부 어휘에 의존)

_BF_EXCEL_EPOCH = datetime(1899, 12, 30)   # 엑셀 시리얼 1 = 1899-12-31
_BF_WEEK_RE = re.compile(r"(\d{1,2})\s*월\s*(\d{1,2})\s*주")
_BF_YMD_RE = re.compile(r"(\d{4})[-./](\d{1,2})[-./](\d{1,2})")
_BF_MD_RE = re.compile(r"(\d{1,2})[/.-](\d{1,2})")
_BF_HDQTS = ('강남', '강북', '인천', '경기', '경남', '경북', '서부', '충청', '강원')


def _bf_norm_hdqt(v) -> str:
    """결과장 region/본부 표기 → 표준 9본부명. 판정 불가('0'/수도권/잡값)는 ''."""
    s = str(v or "").strip()
    if not s:
        return ""
    mapped = _ONS_REGION_MAP.get(s, s)
    if mapped in _BF_HDQTS:
        return mapped
    for h in _BF_HDQTS:
        if s.startswith(h):
            return h
    return ""


def _bf_week(v) -> str:
    m = _BF_WEEK_RE.search(str(v or ""))
    return f"{int(m.group(1))}월 {int(m.group(2))}주차" if m else ""


def _bf_inspect_date(v, year: int) -> str:
    """결과장 검사일자 → 'YYYYMMDD'. 읽지 못하면 ''(검사일 미상)."""
    s = str(v or "").strip()
    if not s or s.upper().startswith("#N/A"):
        return ""
    if s.isdigit():
        n = int(s)
        if len(s) == 8 and 19000101 <= n <= 21001231:
            return s
        if 20000 <= n <= 60000:
            return (_BF_EXCEL_EPOCH + timedelta(days=n)).strftime("%Y%m%d")
        return ""
    m = _BF_YMD_RE.search(s)
    if m:
        return f"{int(m.group(1)):04d}{int(m.group(2)):02d}{int(m.group(3)):02d}"
    if not _BF_WEEK_RE.search(s):
        m = _BF_MD_RE.search(s)
        if m:
            mm, dd = int(m.group(1)), int(m.group(2))
            if 1 <= mm <= 12 and 1 <= dd <= 31:
                return f"{year:04d}{mm:02d}{dd:02d}"
    return ""


def _bf_status(합불여부, 성능서류, 공용화대상) -> str:
    """결과장 합불/성능서류/공용화대상 → 결과 status 어휘 (결과 화면과 동일).

    공용화대상이 ''·'X'·'#N/A'처럼 유형을 못 가리는 값이면 공용화로 본다
    (결과장에 근거가 없고, 부적합의 대다수가 공용화 건이라 운영 합의된 기본값
    — 2026-09-09 결정). '부적합(All)'은 더 쓰지 않는다.
    """
    hb = str(합불여부 or "").strip()
    ps = str(성능서류 or "").strip()
    gy = str(공용화대상 or "").strip()
    if ps == "부적합":
        if "설치장소" in gy:
            return "부적합(설치장소)"
        return "부적합(공용화)"
    if hb == "불합격":
        has_doc, has_perf = ("서류" in ps), ("성능" in ps)
        if has_doc and has_perf:
            return "불합격(All)"
        if has_perf:
            return "불합격(성능)"
        if has_doc:
            return "불합격(서류)"
        return "불합격(All)"
    if hb == "합격":
        return "합격"
    return "검사대기"


def _bf_quarter(ymd: str, week: str) -> str:
    mm = 0
    if len(ymd) == 8 and ymd.isdigit():
        mm = int(ymd[4:6])
    else:
        m = _BF_WEEK_RE.search(week or "")
        if m:
            mm = int(m.group(1))
    return f"{(mm - 1) // 3 + 1}분기" if 1 <= mm <= 12 else ""


class BackfillFromResultsReq(BaseModel):
    year: int
    region: Optional[str] = None      # 결과장 region(표준 본부명) 한 곳만. None=전체
    dry_run: bool = True              # 기본은 미리보기(쓰기 없음)
    overwrite: bool = False           # 이미 결과/일정이 있는 허가번호도 교체
    with_schedules: bool = True       # 일정(inspection_schedules)까지 복원
    add_missing_targets: bool = True  # 대상에 없는 건 스테이징에서 끌어와 등록


def _bf_run_sync(req: BackfillFromResultsReq, actor: str, actor_name: str) -> dict:
    from routers.inspection import INSP_TEAM_TO_HDQT, WF_INSPECTED

    year = req.year
    stats = {
        "year": year, "region": req.region or "전체", "dry_run": req.dry_run,
        "raw_rows": 0, "permits": 0,
        "targets_matched": 0, "targets_missing": 0,
        "targets_from_staging": 0, "targets_unresolved": 0,
        "results_written": 0, "results_skipped": 0,
        "schedules_written": 0, "schedules_skipped": 0,
        "by_region": {},
    }

    conn = sqlite3.connect(_INSP_DB, timeout=120)
    conn.row_factory = sqlite3.Row
    try:
        # 1) 결과장 스캔 — 허가번호당 검사일이 가장 늦은 행(동일하면 id 큰 행) 채택
        sql = ("SELECT id, REPLACE(허가번호,'-','') AS p, region, ons팀, 검사일자 "
               "FROM inspection_results_raw WHERE year=? AND 허가번호 <> ''")
        params: list = [year]
        if req.region:
            sql += " AND region=?"
            params.append(req.region)
        best: dict = {}
        raw_regions: dict = {}
        raw_teams: dict = {}
        for r in conn.execute(sql, params):
            stats["raw_rows"] += 1
            p = (r["p"] or "").strip()
            if not p:
                continue
            key = (_bf_inspect_date(r["검사일자"], year), int(r["id"]))
            if p not in best or key > best[p]:
                best[p] = key
                raw_regions[p] = _bf_norm_hdqt(r["region"])
                raw_teams[p] = str(r["ons팀"] or "").strip()
        best_ids = {p: k[1] for p, k in best.items()}
        stats["permits"] = len(best_ids)
        if not best_ids:
            return stats

        # 2) 대상/기존 결과·일정 대조
        targets: dict = {}
        for r in conn.execute(
                'SELECT 허가번호, 호출명칭, 분기, skt본부, access담당, 품질개선팀 '
                'FROM inspection_targets WHERE year=?', (year,)):
            pno = r["허가번호"]
            if pno in best_ids and pno not in targets:
                targets[pno] = dict(r)
        has_result = {r[0] for r in conn.execute(
            'SELECT 허가번호 FROM inspection_results WHERE year=?', (year,))}
        has_sched = {r[0] for r in conn.execute(
            'SELECT 허가번호 FROM inspection_schedules WHERE year=?', (year,))}

        missing = [p for p in best_ids if p not in targets]
        stats["targets_matched"] = len(best_ids) - len(missing)
        stats["targets_missing"] = len(missing)

        staged_ok: set = set()
        for i in range(0, len(missing), 500):
            batch = missing[i:i + 500]
            ph = ",".join("?" * len(batch))
            staged_ok.update(r[0] for r in conn.execute(
                f'SELECT DISTINCT 허가번호 FROM inspection_targets_staging '
                f'WHERE year=? AND 허가번호 IN ({ph})', [year] + batch))
        stats["targets_from_staging"] = len(staged_ok)
        stats["targets_unresolved"] = len(missing) - len(staged_ok)

        for p in best_ids:
            rg = raw_regions.get(p) or "(미지정)"
            b = stats["by_region"].setdefault(
                rg, {"permits": 0, "대상없음": 0, "스테이징회수": 0})
            b["permits"] += 1
            if p in targets:
                continue
            b["대상없음"] += 1
            if p in staged_ok:
                b["스테이징회수"] += 1

        if req.dry_run:
            writable = [p for p in best_ids
                        if p in targets
                        or (req.add_missing_targets and p in staged_ok)]
            stats["results_written"] = sum(
                1 for p in writable if req.overwrite or p not in has_result)
            stats["results_skipped"] = len(writable) - stats["results_written"]
            if req.with_schedules:
                stats["schedules_written"] = sum(
                    1 for p in writable if req.overwrite or p not in has_sched)
                stats["schedules_skipped"] = (
                    len(writable) - stats["schedules_written"])
            return stats

        now = datetime.now(timezone.utc).isoformat()

        # 3) 대상에 없는 허가번호 → 스테이징에서 회수 (add-from-staging과 동일 경로)
        if req.add_missing_targets and staged_ok:
            _T_COLS = ('year,sheet,pnu_code,허가번호,호출명칭,국종군,부서,분기,연도주기,'
                       '검사주기,허가상태,설치장소,도로명주소,장치수,통시,공대,kca검토결과,'
                       '시기조정,기준연도,skt본부,access담당,품질개선팀,검사종류')
            _t_cols = _T_COLS.split(',')
            ph = ','.join('?' * len(_t_cols))
            for pno in sorted(staged_ok):
                row = conn.execute(
                    'SELECT * FROM inspection_targets_staging '
                    'WHERE year=? AND 허가번호=? LIMIT 1', (year, pno)).fetchone()
                if not row:
                    continue
                d = dict(row)
                d['kca검토결과'] = '대상 추가'
                # 스테이징의 본부/팀 공백 폴백 — 비워 둔 채 올리면 매트릭스에
                # '미배정'으로 잡힌다 (2026-09-09, 2,390건 실측). 실적의
                # region/ons팀을 표준 어휘 검증 후 채운다.
                if not str(d.get('access담당') or '').strip():
                    d['access담당'] = raw_regions.get(pno) or ''
                if not str(d.get('품질개선팀') or '').strip():
                    _rt = raw_teams.get(pno) or ''
                    if _rt in INSP_TEAM_TO_HDQT:
                        d['품질개선팀'] = _rt
                conn.execute(
                    f'INSERT INTO inspection_targets ({_T_COLS}) VALUES ({ph})',
                    tuple(d.get(c) for c in _t_cols))
                conn.execute(
                    'DELETE FROM inspection_targets_staging WHERE year=? AND 허가번호=?',
                    (year, pno))
                targets[pno] = {
                    '허가번호': pno, '호출명칭': d.get('호출명칭') or '',
                    '분기': d.get('분기') or '', 'skt본부': d.get('skt본부') or '',
                    'access담당': d.get('access담당') or '',
                    '품질개선팀': d.get('품질개선팀') or '',
                }
            conn.commit()

        # 4) 결과장 원문을 읽어 결과·일정 적재
        write_permits = [p for p in best_ids if p in targets]
        res_set = {p for p in write_permits if req.overwrite or p not in has_result}
        sch_set = ({p for p in write_permits if req.overwrite or p not in has_sched}
                   if req.with_schedules else set())
        stats["results_skipped"] = len(write_permits) - len(res_set)
        stats["schedules_skipped"] = (
            len(write_permits) - len(sch_set) if req.with_schedules else 0)

        ids = [best_ids[p] for p in write_permits]
        for i in range(0, len(ids), 500):
            batch = ids[i:i + 500]
            ph = ",".join("?" * len(batch))
            for r in conn.execute(
                    f'SELECT * FROM inspection_results_raw WHERE id IN ({ph})',
                    batch).fetchall():
                p = (r["허가번호"] or "").replace("-", "").strip()
                tgt = targets.get(p) or {}
                pk = f"{year}#{p}"
                검사일 = _bf_inspect_date(r["검사일자"], year)
                주차 = _bf_week(r["주차별"])
                status = _bf_status(r["합불여부"], r["성능서류"], r["공용화대상"])
                # 입력자/등록자 ← 실적(raw)의 uploaded_by (결과장 업로더).
                # 수검자는 결과 테이블의 수검자 컬럼에 별도로 들어간다 (아래 INSERT).
                기록자 = (str(r["uploaded_by"] or "").strip() or actor_name)[:100]
                # 재점검 기준은 결과 입력 라우터와 동일 (합격/빈값/검사대기 외 = 재점검)
                needs_recheck = ('1' if status.strip() not in ('합격', '', '검사대기')
                                 else '0')
                if p in res_set:
                    existing = conn.execute(
                        'SELECT 사진S3키, 사진업로더 FROM inspection_results WHERE pk=?',
                        (pk,)).fetchone()
                    photos = existing['사진S3키'] if existing else '[]'
                    uploaders = (existing['사진업로더'] or '{}') if existing else '{}'
                    conn.execute('''INSERT OR REPLACE INTO inspection_results
                        (pk, year, 허가번호, status, 검사일, 메모, 철탑형태,
                         사진S3키, 사진업로더, 입력자, 입력일시, schedule_pk, needs_recheck,
                         진행여부, 성능서류, 불합격내용, 불합격상세, 공용화대상,
                         간략불합격, 기타사항, 수검자, 시스템, 기지국구분,
                         전파진흥원, 검사관, 주차별)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                        (pk, year, p, status, 검사일,
                         r["불합격상세"] or "",      # 특이사항 메모 ← 불합격 상세사유
                         "", photos, uploaders, 기록자, now, pk, needs_recheck,
                         r["진행여부"] or "", r["성능서류"] or "",
                         (r["불합격내용"] or "")[:200], r["불합격상세"] or "",
                         (r["공용화대상"] or "")[:100], (r["간략불합격"] or "")[:200],
                         r["기타사항"] or "", (r["수검자"] or "")[:100],
                         (r["시스템"] or "")[:100], (r["기지국구분"] or "")[:100],
                         (r["전파진흥원"] or "")[:100], (r["검사관"] or "")[:100],
                         (r["주차별"] or "")[:50]))
                    stats["results_written"] += 1
                if p in sch_set:
                    # 본부/팀: 대상 값 우선, 폴백은 결과장 정규화 (표준 어휘만 저장)
                    본부 = raw_regions.get(p) or ""
                    raw_team = str(r["ons팀"] or "").strip()
                    팀 = raw_team if raw_team in INSP_TEAM_TO_HDQT else ""
                    if 팀 and not 본부:
                        본부 = INSP_TEAM_TO_HDQT[팀]
                    conn.execute('''INSERT OR REPLACE INTO inspection_schedules
                        (pk, year, 허가번호, 호출명칭, 분기, skt본부, access담당,
                         품질개선팀, 수검예정주차, 수검시작일, 수검종료일, 지역,
                         등록자, 등록일시, 검사관, 조,
                         workflow_status, status_updated_at, status_updated_by)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                        (pk, year, p,
                         (tgt.get("호출명칭") or r["호출명칭"] or "")[:200],
                         (tgt.get("분기") or _bf_quarter(검사일, r["주차별"] or ""))[:20],
                         (tgt.get("skt본부") or _bf_norm_hdqt(r["skt본부"]))[:50],
                         (tgt.get("access담당") or 본부)[:50],
                         (tgt.get("품질개선팀") or 팀)[:50],
                         주차, "", "", "",
                         기록자, now, (r["검사관"] or "")[:100], "",
                         WF_INSPECTED, now, actor))
                    # 상태 이력은 직접 기록 — _wf_record_log_sync 는 전환 알림을
                    # 발송하므로 수만 건 백필에 쓰면 알림 폭주가 난다.
                    conn.execute(
                        'INSERT INTO inspection_status_log(schedule_pk, from_status, '
                        'to_status, changed_by, changed_at, memo) VALUES (?,?,?,?,?,?)',
                        (pk, None, WF_INSPECTED, actor, now, "실적(결과장) 백필 복원"))
                    stats["schedules_written"] += 1
            conn.commit()
        conn.commit()
    finally:
        conn.close()
    return stats


@router.post("/inspection-results/backfill")
async def inspection_results_backfill(request: Request, req: BackfillFromResultsReq):
    """결과장(실적)을 원본으로 수검 일정·결과 이력 복원 (admin/manager).

    dry_run=True(기본)면 쓰기 없이 본부별 반영 건수만 집계해 반환.
    기본은 기존 결과·일정이 있는 허가번호를 건너뛴다(기존 입력분 보존).
    overwrite=True면 키 단위 교체(사진은 보존). 재실행 안전.
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    try:
        from routers.inspection import _get_user_info_for_community
        info = await asyncio.to_thread(_get_user_info_for_community, empno)
        actor_name = info.get("name", empno) or empno
    except Exception:
        actor_name = empno

    stats = await asyncio.to_thread(_bf_run_sync, req, empno, actor_name)

    try:
        from routers.inspection import _record_audit_log_sync
        await asyncio.to_thread(
            _record_audit_log_sync, "inspection_backfill_from_results",
            "inspection_results_raw",
            f"year={req.year},region={req.region or '전체'},dry_run={req.dry_run},"
            f"overwrite={req.overwrite},결과={stats['results_written']},"
            f"일정={stats['schedules_written']}", empno)
    except Exception as e:
        logger.warning(f"백필 감사로그 기록 실패 (무시): {e}")

    logger.info(f"실적 백필: {stats}")
    return {"success": True, **stats}
