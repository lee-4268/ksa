from django.contrib.auth import get_user_model
from django.db import models

class UserProfile(models.Model):
    user = models.OneToOneField(get_user_model(), on_delete=models.CASCADE)
    created_at = models.DateTimeField(auto_now_add=True, verbose_name="생성일시")
    updated_at = models.DateTimeField(auto_now=True, verbose_name="수정일시")
    deactivate_date = models.DateField(blank=True, null=True, verbose_name="비활성화일자")
    phone_number = models.CharField(max_length=15, blank=True, null=True, verbose_name="전화번호")
    region = models.CharField(max_length=100, blank=True, null=True, verbose_name="담당/본부")
    team = models.CharField(max_length=100, blank=True, null=True, verbose_name="팀")
    job_title = models.CharField(max_length=100, blank=True, null=True, verbose_name="직책")

    def __str__(self):
        return self.user.username

# 유저들이 어느 히스토리를 가장 많이 파악하는 지 단순히 알아가기 위한 히스토리 모델
class UserFilterHistory(models.Model):
    user = models.ForeignKey(get_user_model(), on_delete=models.CASCADE, related_name='filter_history')
    team = models.CharField(max_length=100, blank=True, null=True, verbose_name="팀")
    created_at = models.DateTimeField(auto_now_add=True, verbose_name="생성일시")

    class Meta:
        db_table = 'history_userfilterhistory'  # 기존 테이블 이름 사용
        ordering = ['-created_at']
        verbose_name = "사용자 필터 이력"
        verbose_name_plural = "사용자 필터 이력"



class Regions(models.Model):

    sequence = models.IntegerField(default=99, verbose_name="순서")
    region = models.CharField(max_length=20, verbose_name="담당조직")
    is_active = models.BooleanField(default=True) # True: 활성화, False: 비활성화
    year = models.IntegerField(default=2025) # 년도

    def __str__(self):
        return self.region

    class Meta:
        ordering = ['-year','sequence']
        verbose_name = "담당조직"
        verbose_name_plural = "담당조직"



class Teams(models.Model):
    sequence = models.IntegerField(default=99, verbose_name="순서")
    region = models.ForeignKey(Regions, on_delete=models.CASCADE)
    team_name = models.CharField(max_length=20, verbose_name="팀명")
    is_active = models.BooleanField(default=True) # True: 활성화, False: 비활성화
    year = models.IntegerField(default=2024) # 년도

    def __str__(self):
        return self.team_name

    class Meta:
        ordering = ['-year','sequence']
        verbose_name = "팀명"
        verbose_name_plural = "팀명"

