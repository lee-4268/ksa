from rest_framework import serializers
from django.contrib.auth import get_user_model
from .models import UserProfile, Regions, Teams

User = get_user_model()

# auth_user (혹은 커스텀 User) 정보 전용 Serializer
class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        # 필요한 필드를 선택하세요. 예: id, username, email 등을 포함
        fields = ('username', 'first_name')


class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    first_name = serializers.CharField(source='user.first_name', read_only=True)

    class Meta:
        model = UserProfile
        fields = (
            'id',
            'username',
            'first_name',
            'region',
            'team',
            'job_title',
        )

class RegionsSerializer(serializers.ModelSerializer):
    class Meta:
        model = Regions
        fields = (
            'id',
            'region',
            'year',
            'sequence'
        )

class TeamsSerializer(serializers.ModelSerializer):
    place_name = serializers.SerializerMethodField()

    class Meta:
        model = Teams
        fields = (
            'id',
            'team_name',
            'place_name',
            'year',
            'sequence'
        )

    def get_place_name(self, obj):
        return obj.team_name.replace("품질개선팀", "").strip()