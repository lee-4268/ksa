from django.conf import settings
import requests
import hashlib
import base64
import json

# define
TOKEN_URL = settings.TOKEN_URL
VALIDATE_URL = settings.VALIDATE_URL

CLIENT_IDENTIFIER = settings.CLIENT_IDENTIFIER
CLIENT_SECRET =  settings.CLIENT_SECRET
AUTH_METHOD = settings.AUTH_METHOD
SCOPES = settings.SCOPES

SALT = settings.SALT

def auth_login_api(user_name, password_plain):
    url = "https://auth.skons.net/accounts/sko/sso/login/"

    payload = json.dumps({
        "username": user_name,
        "password": password_plain,
    })
    headers = {
        'Content-Type': 'application/json',
        'Cookie': 'sessionid=yba4shbp5uo4aia7rq2yzc0emizyn51m'
    }

    response = requests.request("POST", url, headers=headers, data=payload)

    return response.text


def encrypt_password(password_plain):
    combined = f"{password_plain}{SALT}"
    hash_digest = hashlib.sha256(combined.encode('utf-8')).digest()
    encoded_password = base64.b64encode(hash_digest).decode('utf-8')
    return encoded_password


def request_login_token(user_name, encrypted_password):
    headers = {
        'Content-Type': 'application/json; charset=utf-8'
    }
    payload = {
        "clientIdentifier": CLIENT_IDENTIFIER,
        "clientSecret": CLIENT_SECRET,
        "userName": user_name,
        "password": encrypted_password,
        "authMethod": AUTH_METHOD,
        "scopes": SCOPES
    }

    response = requests.post(TOKEN_URL, json=payload, headers=headers)

    # Check if the response is successful
    if response.status_code == 200:
        token_result = response.json().get('RequestTokenResult', '')
        if token_result:
            # Check if the token is not empty
            return {"success": True, "token": token_result}
        else:
            return {"success": False, "message": "Authentication failed, empty token."}
    else:
        return {"success": False, "message": response.text}



def validate_token(access_token):
    headers = {
        'Content-Type': 'application/json; charset=utf-8'
    }

    payload = {
        "clientIdentifier": CLIENT_IDENTIFIER,
        "clientSecret": CLIENT_SECRET,
        "accessToken": access_token
    }

    response = requests.post(VALIDATE_URL, json=payload, headers=headers)

    if response.status_code == 200:
        result = response.json().get('AccessProtectedResourceResult', '')
        try:
            result_data = json.loads(result)
            return {
                "success": True,
                "data": result_data
            }
        except json.JSONDecodeError:
            return {
                "success": False,
                "message": "Invalid token or unexpected response format."
            }
    else:
        return {
            "success": False,
            "message": response.text
        }