import csv
import os
from datetime import date
from django.db import transaction
from django.conf import settings
from django.core.management.base import BaseCommand
from django.contrib.auth.models import User
from accounts.models import UserProfile

class Command(BaseCommand):
    help = (
        '지정된 날짜의 사용자 데이터를 CSV파일에서 불러와 사용자 정보를 업데이트합니다.\n'
        'CSV 파일명 형식: inet_YYMMDD.csv (예: inet_250320.csv)\n'
        '파일 위치: 프로젝트 루트 디렉터리의 files/ 디렉터리 아래에 위치해야 합니다.'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--file',
            type=str,
            required=True,
            help='CSV 파일 이름 (예시: inet_20250320.csv). 파일은 프로젝트 루트의 files/ 아래 위치해야 합니다.'
        )

    @transaction.atomic
    def handle(self, *args, **options):
        filename = options['file']
        file_path = os.path.join(settings.BASE_DIR, 'files', filename)

        if not os.path.exists(file_path):
            self.stderr.write(self.style.ERROR(f"파일을 찾을 수 없습니다: {file_path}"))
            return

        exclude_users = set(getattr(settings, 'USER_DEACTIVATE_EXCLUDE_LIST', []))

        existing_users = set(User.objects.values_list('username', flat=True))
        csv_users = set()
        failed_users = []

        with open(file_path, newline='', encoding='utf-8') as csvfile:
            reader = csv.DictReader(csvfile)

            for row in reader:
                username = row['empno'].strip()
                csv_users.add(username)

                try:
                    user, created = User.objects.update_or_create(
                        username=username,
                        defaults={
                            'first_name': row.get('name', '').strip(),
                            'email': row.get('Email', '').strip(),
                            'is_active': True,
                        }
                    )

                    UserProfile.objects.update_or_create(
                        user=user,
                        defaults={
                            'phone_number': row.get('MobilePhone', '').strip(),
                            'region': row.get('region', '').strip(),
                            'team': row.get('PartyTeamName', '').strip(),
                            'job_title': row.get('jobGdName', '').strip(),
                            'deactivate_date': None,  # 재활성화 시 초기화
                        }
                    )

                    action = "생성" if created else "업데이트"
                    self.stdout.write(self.style.SUCCESS(
                        f"{action} 완료: {username}"
                    ))

                except Exception as e:
                    failed_users.append((username, str(e)))
                    self.stderr.write(self.style.ERROR(
                        f"처리 실패: {username}, 오류: {e}"
                    ))

        # CSV에 없고, exclude_users에도 없는 사용자 비활성화 처리 및 deactivate_date 기록
        users_to_deactivate = existing_users - csv_users - exclude_users
        today = date.today()
        for username in users_to_deactivate:
            User.objects.filter(username=username).update(is_active=False)
            UserProfile.objects.filter(user__username=username).update(deactivate_date=today)

        self.stdout.write(self.style.WARNING(
            f"비활성화 처리된 사용자 수: {len(users_to_deactivate)} (비활성화일자: {today})"
        ))

        if exclude_users:
            self.stdout.write(self.style.SUCCESS(
                f"예외 처리로 비활성화에서 제외된 사용자: {', '.join(exclude_users)}"
            ))

        # 실패 사용자 리스트 출력
        if failed_users:
            self.stderr.write(self.style.ERROR("\n처리되지 않은 사용자 리스트:"))
            for username, error_msg in failed_users:
                self.stderr.write(f"- {username}: {error_msg}")
        else:
            self.stdout.write(self.style.SUCCESS("\n모든 사용자 처리 완료"))