from django.utils.decorators import method_decorator
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from rest_framework.authtoken.models import Token
from datetime import datetime
from accounts.models import UserProfile, Regions, Teams, UserFilterHistory
from accounts.backends.skons_auth_api import auth_login_api
import json
from django.conf import settings
from .serializers import UserSerializer, UserProfileSerializer, RegionsSerializer, TeamsSerializer
from django.core.cache import cache
from django.contrib.auth import login, logout
from django.contrib.auth.models import User
from rest_framework.permissions import IsAuthenticated
from django.views.decorators.csrf import csrf_exempt



class TeamFilterAPIView(APIView):
    def post(self, request):
        # 팀
        user_id = request.data.get('user_id')
        team = request.data.get('team')

        cache.set(user_id, team, timeout=60*60*24)
        test = cache.get(user_id)
        return Response({"message": "팀 정보가 저장되었습니다."}, status=status.HTTP_200_OK)


@method_decorator(csrf_exempt, name="dispatch")
class LoginView(APIView):
    authentication_classes = []      # ← 여기에 추가!
    permission_classes = []

    def post(self, request):
        username = request.data.get("username")
        password = request.data.get("password")

        output = json.loads(auth_login_api(user_name=username, password_plain=password)).get("result")
        if output != "ok":
            return Response({"message": "로그인 실패"}, status=status.HTTP_401_UNAUTHORIZED)

        # ② Django User 확보(없으면 생성)
        user, _ = User.objects.get_or_create(username=username)

        # ③ Django 세션 로그인
        login(request, user)

        # ④ 프로필 직렬화
        profile = UserProfile.objects.filter(user=user).first()
        if not profile:
            return Response({"message": "해당 유저가 존재하지 않습니다."},
                            status=status.HTTP_404_NOT_FOUND)

        data = UserProfileSerializer(profile).data
        return Response(data, status=status.HTTP_200_OK)

@method_decorator(csrf_exempt, name="dispatch")
class LogoutView(APIView):
    authentication_classes = []      # ← 여기에 추가!
    permission_classes = []

    def post(self, request):
        logout(request)
        # 2) Response 생성 후 쿠키 만료 헤더 추가
        response = Response({"message": "로그아웃 완료"}, status=status.HTTP_200_OK)
        from django.middleware.csrf import get_token

        get_token(request)

        # 세션 flush + 쿠키 만료
        return Response({"message": "로그아웃 완료"}, status=status.HTTP_200_OK)

class RegionAPIView(APIView):
    permission_classes = [IsAuthenticated]         # 세션 인증 필요
    def get(self, request):
        # 현재 년도 가져오기
        current_year = datetime.now().year
        regions = Regions.objects.filter(is_active=True,
                                         year=current_year,
                                         region__icontains="Access").order_by('sequence')
        serializer = RegionsSerializer(regions, many=True)
        return Response(serializer.data, status=status.HTTP_200_OK)


class TeamAPIView(APIView):
    permission_classes = [IsAuthenticated]         # 세션 인증 필요
    def get(self, request):
        current_year = datetime.now().year
        region_id = request.query_params.get("region_id")
        if not region_id:
            return Response({"message": "region_id가 필요합니다."}, status=status.HTTP_400_BAD_REQUEST)
        teams = Teams.objects.filter(is_active=True,
                                     year=current_year,
                                     region_id=region_id,
                                     team_name__icontains="품질개선").order_by('sequence')
        if not teams.exists():
            return Response({"message": "해당 팀이 존재하지 않습니다."}, status=status.HTTP_404_NOT_FOUND)
        serializer = TeamsSerializer(teams, many=True)
        return Response(serializer.data, status=status.HTTP_200_OK)