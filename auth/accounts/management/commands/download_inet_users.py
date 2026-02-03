"""
인사DB로부터 인트라넷 사용자 정보를 다운로드하고 CSV로 저장하는 Django 관리 명령어입니다.
이 명령어는 인사DB에 연결하여 사용자 정보를 쿼리하고, 결과를 CSV 파일로 저장합니다.

사전조건 :
1. Django 프로젝트가 설정되어 있어야 합니다.
2. pymssql 및 pandas 라이브러리가 설치되어 있어야 합니다.
3. Django settings.py 파일에 BASE_DIR이 설정되어 있어야 합니다.
4. 사내망에서 접속하여 DB에 접근할 수 있어야 합니다.(vpn포함)

사용법:
python manage.py download_inet_users

"""
import os
import time
import pymssql
import pandas as pd
from pathlib import Path
from django.conf import settings
from django.core.management.base import BaseCommand

class Command(BaseCommand):
    help = '인사DB로부터 인트라넷 사용자 정보를 다운로드하고 CSV로 저장합니다'

    def handle(self, *args, **options):
        # 저장 경로 설정
        save_dir = Path(settings.BASE_DIR)  / 'files'

        # 디렉토리가 없으면 생성
        os.makedirs(save_dir, exist_ok=True)

        conn = pymssql.connect(server='172.19.152.78', user='onsuser1', password='ons12345!', database='Common')

        query_string = '''
        with step1 as (
            select empno, name, Email, MobilePhone,JobGDCode,
                   TB_ZZ_User.DeptCode, DeptName, PartyTeamName, HiredDate
            from TB_ZZ_User
                     left join (select *
                                from TB_CM_DeptCode
                                where  UseYn = 'Y'
            ) TCDC
                               on TB_ZZ_User.OrgDeptCode = TCDC.DeptCode
            where (left(empno, 3) = 'N10' or left(EmpNo, 3) = 'N11' or left(EmpNo, 3) = 'N15' or left(EmpNo, 3) = 'N16')
               and TB_ZZ_User.UseYN = 'Y' -- 퇴사자까지 포함해야 과거 수행이럭이 날아가지 않는다.
        ),
        step2 as(
            select JobGdCode, JobGdName from TB_CM_JobGrade where UseYn = 'Y'
        )
        select empno, name, Email, MobilePhone, DeptName, PartyTeamName, step1.JobGDCode, HiredDate, jobGdName
        from step1
        left join step2
        on step1.JobGDCode = step2.JobGdCode and (DeptName is not null or DeptName <> '')
        ;
        '''

        df_inet = pd.read_sql(query_string, con=conn)

        df_inet.dropna(subset=['DeptName'], inplace=True)

        df = df_inet.copy()

        # region명 추출
        df['region'] = df[['DeptName', 'PartyTeamName']].apply(lambda x: x['PartyTeamName'].replace(x['DeptName'], '').strip(), axis=1)
        df.loc[df['region'].str.len() == 0, 'region'] = 'SK오앤에스(주)'  # 대표이사의 경우

        df['region'] = df['region'].str.strip()

        # pandas 경고 수정
        df = df.copy()
        df['jobGdName'] = df['jobGdName'].fillna('')

        # 팀명에서는 그 사람의 본인 소속 조직이다. region은 그의 상위 조직이 된다.
        conn.close()
        del (conn)

        # CSV 파일로 저장, 파일명은 inet_YYYYMMDD.csv 형식으로 저장
        today = time.strftime('%Y%m%d')
        csv_file_name = f'inet_{today}.csv'

        csv_file_path = save_dir / csv_file_name

        # CSV 파일로 저장
        df.to_csv(csv_file_path, index=False)

        self.stdout.write(self.style.SUCCESS(f"CSV 파일이 {csv_file_path}에 저장되었습니다."))