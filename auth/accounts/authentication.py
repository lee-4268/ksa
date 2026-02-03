# from rest_framework.authentication import BaseAuthentication
# from rest_framework.exceptions import AuthenticationFailed
# from django.contrib.auth.models import AnonymousUser, User
# from accounts.backends.skons_auth_api import validate_token
#
# class ExternalTokenAuthentication(BaseAuthentication):
# 	def authenticate(self, request):
# 		token = None
#
# 		# ① Authorization 헤더 우선
# 		auth_header = request.headers.get("Authorization")
# 		if auth_header and auth_header.startswith("Bearer "):
# 			token = auth_header.split("Bearer ")[1]
#
# 		# ② 없으면 쿠키 fallback
# 		if token is None:
# 			token = request.COOKIES.get("access_token")
#
# 		if token is None:
# 			return None  # 인증 시도 안 함
#
# 		validation_result = validate_token(token)
# 		if not validation_result["success"]:
# 			raise AuthenticationFailed("Invalid or expired token")
#
# 		username = validation_result["data"]["name"]
# 		user, _ = User.objects.get_or_create(username=username)
#
# 		return (user, token)
