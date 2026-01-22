$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
aws s3 sync "C:\Users\user\Desktop\26\ksa\build\web" s3://radio-inspection-web --delete
