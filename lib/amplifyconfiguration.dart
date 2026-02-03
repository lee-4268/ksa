const amplifyconfig = '''{
    "UserAgent": "aws-amplify-cli/2.0",
    "Version": "1.0",
    "auth": {
        "plugins": {
            "awsCognitoAuthPlugin": {
                "IdentityManager": {
                    "Default": {}
                },
                "CredentialsProvider": {
                    "CognitoIdentity": {
                        "Default": {
                            "PoolId": "ap-northeast-2:dffd1404-6954-4b31-9610-9851fe39cd57",
                            "Region": "ap-northeast-2"
                        }
                    }
                }
            }
        }
    },
    "api": {
        "plugins": {
            "awsAPIPlugin": {
                "ksa": {
                    "endpointType": "GraphQL",
                    "endpoint": "https://mtokcw2pmffyjdhl3uhfihwj7m.appsync-api.ap-northeast-2.amazonaws.com/graphql",
                    "region": "ap-northeast-2",
                    "authorizationType": "API_KEY",
                    "apiKey": "da2-xx7exqdwgjgqjlsi5sl6oenv3u"
                }
            }
        }
    },
    "storage": {
        "plugins": {
            "awsS3StoragePlugin": {
                "bucket": "ksa-photos-bucket1d5de-dev",
                "region": "ap-northeast-2",
                "defaultAccessLevel": "guest"
            }
        }
    }
}''';
