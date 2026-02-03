from django.urls import path
from accounts.views import LoginView, TeamFilterAPIView, RegionAPIView, TeamAPIView, LogoutView

app_name = 'accounts'

urlpatterns = [
    path('login/', LoginView.as_view(), name='login'),
    path('logout/', LogoutView.as_view(), name='logout'),
    path('team/', TeamFilterAPIView.as_view(), name='team_filter'),
    path('regions/', RegionAPIView.as_view(), name='regions'),
    path('teams/', TeamAPIView.as_view(), name='teams'),
]