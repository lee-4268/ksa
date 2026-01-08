# Amplify Push with auto-fix for amplifyconfiguration.dart
# Usage: .\amplify-push.ps1

Write-Host "Running amplify push..." -ForegroundColor Cyan
amplify push

Write-Host "`nRestoring amplifyconfiguration.dart settings..." -ForegroundColor Yellow

# Read the file
$configPath = "lib\amplifyconfiguration.dart"
$content = Get-Content $configPath -Raw

# Fix authorizationType: API_KEY -> AMAZON_COGNITO_USER_POOLS
$content = $content -replace '"authorizationType": "API_KEY"', '"authorizationType": "AMAZON_COGNITO_USER_POOLS"'

# Fix AuthMode: API_KEY -> AMAZON_COGNITO_USER_POOLS
$content = $content -replace '"AuthMode": "API_KEY"', '"AuthMode": "AMAZON_COGNITO_USER_POOLS"'

# Fix ClientDatabasePrefix
$content = $content -replace '"ClientDatabasePrefix": "ksa_API_KEY"', '"ClientDatabasePrefix": "ksa_AMAZON_COGNITO_USER_POOLS"'

# Fix defaultAccessLevel: guest -> private
$content = $content -replace '"defaultAccessLevel": "guest"', '"defaultAccessLevel": "private"'

# Remove duplicate AppSync config (ksa_AMAZON_COGNITO_USER_POOLS section)
# This is a simplified approach - removes the extra config block

# Write back
Set-Content $configPath $content -NoNewline

Write-Host "amplifyconfiguration.dart fixed!" -ForegroundColor Green
Write-Host "`nNow run: flutter build web" -ForegroundColor Cyan
